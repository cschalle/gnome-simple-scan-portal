/*
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

/* Scanning through the proposed org.freedesktop.portal.Scanner interface instead of libsane.
 *
 * The scanner's options become ScanOptions with the same names SANE uses, and a frame's pixels
 * are read from a pipe, so the scan thread works as it does with libsane. Every method is
 * called from the scan thread and blocks; only the D-Bus signal handlers run in the main
 * thread, and they just queue what they receive. */
public class PortalBackend : Object, ScanBackend
{
    private const string PORTAL_PATH = "/org/freedesktop/portal/desktop";
    private const string SCANNER_IFACE = "org.freedesktop.portal.Scanner";
    private const string REQUEST_IFACE = "org.freedesktop.portal.Request";
    private const string SESSION_IFACE = "org.freedesktop.portal.Session";

    /* How long to wait for the user to choose a scanner, and for a frame to start (lamp warm-up) */
    private const int64 SELECT_TIMEOUT_US = 10 * 60 * 1000000;
    private const int64 START_TIMEOUT_US = 120 * 1000000;
    private const int64 FINISH_TIMEOUT_US = 20 * 1000000;
    private const int CALL_TIMEOUT_MS = 120000;

    private class Event
    {
        public string state;
        public Variant details;
        public uint32 frame;
    }

    private DBusConnection? bus;
    private string bus_name;
    private uint frame_subscription;
    private AsyncQueue<Event> frame_events = new AsyncQueue<Event> ();
    private AsyncQueue<Variant> responses = new AsyncQueue<Variant> ();
    private int request_counter;

    /* The number of the latest frame whose end was seen: events numbered at or below it belong to
     * a frame that is over, such as one that was cancelled, and are dropped. */
    private uint32 done_frame;

    private string? session;
    private ScanOption[]? options;
    private bool options_stale;

    private Sane.Parameters parameters;
    private int pipe_fd = -1;
    private bool frame_running;

    public PortalBackend ()
    {
        /* The prototype portal has its own bus name; the real one is on the portal's name */
        bus_name = Environment.get_variable ("SIMPLE_SCAN_PORTAL_BUS_NAME") ?? "org.freedesktop.portal.Desktop";
    }

    public bool init ()
    {
        try
        {
            bus = Bus.get_sync (BusType.SESSION);
        }
        catch (Error e)
        {
            warning ("Unable to connect to the session bus: %s", e.message);
            return false;
        }

        frame_subscription = bus.signal_subscribe (bus_name, SCANNER_IFACE, "FrameEvent", PORTAL_PATH, null,
                                                   DBusSignalFlags.NONE, frame_event_cb);
        debug ("Using the scanner portal on %s", bus_name);
        return true;
    }

    public void exit ()
    {
        close ();
        if (bus != null)
        {
            bus.signal_unsubscribe (frame_subscription);
            bus = null;
        }
    }

    /* The next event of the frame in progress, or null after the timeout */
    private Event? next_event (int64 timeout_us)
    {
        var deadline = get_monotonic_time () + timeout_us;
        while (true)
        {
            var remaining = deadline - get_monotonic_time ();
            var event = frame_events.timeout_pop (remaining > 0 ? (uint64) remaining : 0);
            if (event == null)
                return null;
            if (event.frame != 0 && event.frame <= done_frame)
                continue;
            if (event.frame != 0 && event.state != "started")
                done_frame = event.frame;
            return event;
        }
    }

    /* Signal handlers run in the main thread */
    private void frame_event_cb (DBusConnection connection, string? sender, string object_path, string interface_name,
                                 string signal_name, Variant params)
    {
        string event_session;
        string state;
        Variant details;
        params.get ("(os@a{sv})", out event_session, out state, out details);

        /* Events of other sessions, such as one this application closed, are not ours */
        if (event_session != session)
            return;

        var event = new Event ();
        event.state = state;
        event.details = details;
        var frame = details.lookup_value ("frame", VariantType.UINT32);
        event.frame = frame != null ? frame.get_uint32 () : 0;
        frame_events.push (event);
    }

    private void response_cb (DBusConnection connection, string? sender, string object_path, string interface_name,
                              string signal_name, Variant params)
    {
        responses.push (params);
    }

    private static Variant empty_dict ()
    {
        return new Variant.array (new VariantType ("{sv}"), {});
    }

    private static Sane.Status status_of_error (Error e)
    {
        var name = DBusError.get_remote_error (e);
        debug ("Portal error: %s (%s)", e.message, name != null ? name : "local");
        switch (name)
        {
        case "org.freedesktop.portal.Error.Busy":
            return Sane.Status.DEVICE_BUSY;
        case "org.freedesktop.portal.Error.InvalidArgument":
            return Sane.Status.INVAL;
        case "org.freedesktop.portal.Error.NotAllowed":
            return Sane.Status.ACCESS_DENIED;
        default:
            return Sane.Status.IO_ERROR;
        }
    }

    private Variant call (string method, Variant? args, string? iface = null, string? path = null) throws Error
    {
        return bus.call_sync (bus_name, path ?? PORTAL_PATH, iface ?? SCANNER_IFACE, method, args, null,
                              DBusCallFlags.NONE, CALL_TIMEOUT_MS);
    }

    private static string? dict_string (Variant dict, string key)
    {
        var v = dict.lookup_value (key, VariantType.STRING);
        return v != null ? v.get_string () : null;
    }

    /* Ask the user which scanners the application may use, and wait for the answer */
    private bool select_scanners ()
    {
        var token = "simple_scan%d".printf (++request_counter);
        var request_path = "%s/request/%s/%s".printf (PORTAL_PATH, bus.get_unique_name ().substring (1).replace (".", "_"), token);

        while (responses.try_pop () != null);
        var subscription = bus.signal_subscribe (bus_name, REQUEST_IFACE, "Response", request_path, null,
                                                 DBusSignalFlags.NONE, response_cb);
        try
        {
            var opts = new VariantBuilder (new VariantType ("a{sv}"));
            opts.add ("{sv}", "handle_token", new Variant.string (token));
            opts.add ("{sv}", "multiple", new Variant.boolean (true));
            /* Scanners for documents: the portal does not offer film scanners, which are for negatives */
            opts.add ("{sv}", "any_capabilities", new Variant.strv ({ "flatbed", "adf" }));
            call ("SelectScanners", new Variant ("(sa{sv})", "", opts));

            var response = responses.timeout_pop (SELECT_TIMEOUT_US);
            if (response == null)
            {
                warning ("No answer to the scanner selection");
                return false;
            }
            uint code;
            Variant results;
            response.get ("(u@a{sv})", out code, out results);
            debug ("SelectScanners -> response %u", code);
            return code == 0;
        }
        catch (Error e)
        {
            warning ("Unable to ask for scanners: %s", e.message);
            return false;
        }
        finally
        {
            bus.signal_unsubscribe (subscription);
        }
    }

    private Sane.Status list_scanners (out List<ScanDeviceInfo> list)
    {
        list = new List<ScanDeviceInfo> ();
        try
        {
            var reply = call ("ListScanners", new Variant ("(@a{sv})", empty_dict ()));
            var scanners = reply.get_child_value (0);
            for (var i = 0; i < scanners.n_children (); i++)
            {
                var scanner = scanners.get_child_value (i);
                var info = new ScanDeviceInfo ();
                info.name = scanner.get_child_value (0).get_string ();
                var details = scanner.get_child_value (1);
                info.vendor = dict_string (details, "vendor") ?? "";
                info.model = dict_string (details, "model") ?? dict_string (details, "name") ?? info.name;
                info.type = dict_string (details, "type") ?? dict_string (details, "kind") ?? "";
                list.append (info);
            }
            return Sane.Status.GOOD;
        }
        catch (Error e)
        {
            warning ("Unable to list scanners: %s", e.message);
            return status_of_error (e);
        }
    }

    public bool select_devices ()
    {
        return select_scanners ();
    }

    public Sane.Status get_devices (out ScanDeviceInfo?[] devices)
    {
        List<ScanDeviceInfo> list;
        var status = list_scanners (out list);

        /* The application only sees what the user granted, so with nothing granted yet, ask */
        if (status == Sane.Status.GOOD && list.length () == 0 && select_scanners ())
            status = list_scanners (out list);

        var n = (int) list.length ();
        devices = new ScanDeviceInfo?[n + 1];
        for (var i = 0; i < n; i++)
            devices[i] = list.nth_data (i);
        return status;
    }

    public Sane.Status open (string device)
    {
        try
        {
            var reply = call ("OpenScanner", new Variant ("(s@a{sv})", device, empty_dict ()));
            session = reply.get_child_value (0).get_string ();
            debug ("OpenScanner (\"%s\") -> %s", device, session);
        }
        catch (Error e)
        {
            warning ("Unable to open scanner: %s", e.message);
            return status_of_error (e);
        }

        while (frame_events.try_pop () != null);
        done_frame = 0;
        return fetch_options ();
    }

    public void close ()
    {
        cancel ();
        if (session != null)
        {
            try
            {
                call ("Close", null, SESSION_IFACE, session);
            }
            catch (Error e)
            {
                debug ("Unable to close session: %s", e.message);
            }
            debug ("Session.Close ()");
            session = null;
        }
        options = null;
    }

    public void cancel ()
    {
        if (!frame_running)
            return;

        try
        {
            call ("Cancel", new Variant ("(o)", session));
        }
        catch (Error e)
        {
            debug ("Unable to cancel: %s", e.message);
        }
        end_frame ();
        debug ("Cancel ()");
    }

    /* The frame is over: nothing more to read, and anything it queued is stale */
    private void end_frame ()
    {
        if (pipe_fd >= 0)
        {
            Posix.close (pipe_fd);
            pipe_fd = -1;
        }
        if (frame_running)
        {
            frame_running = false;
            /* Wait for the portal to confirm, so its next frame does not meet this one's events */
            Event? event = null;
            do
                event = next_event (FINISH_TIMEOUT_US);
            while (event != null && event.state == "started");
        }
    }

    /* Options */

    private static Sane.Int cap_of (Variant d)
    {
        var caps = d.lookup_value ("capabilities", new VariantType ("as"));
        int cap = 0;
        if (caps != null)
        {
            foreach (var c in caps.get_strv ())
            {
                switch (c)
                {
                case "settable":
                    cap |= Sane.Capability.SOFT_SELECT;
                    break;
                case "readable":
                    cap |= Sane.Capability.SOFT_DETECT;
                    break;
                case "hardware":
                    cap |= Sane.Capability.HARD_SELECT;
                    break;
                case "emulated":
                    cap |= Sane.Capability.EMULATED;
                    break;
                case "inactive":
                    cap |= Sane.Capability.INACTIVE;
                    break;
                case "advanced":
                    cap |= Sane.Capability.ADVANCED;
                    break;
                case "automatic":
                    cap |= Sane.Capability.AUTOMATIC;
                    break;
                }
            }
        }
        return (Sane.Int) cap;
    }

    private static Sane.ValueType type_of (string? type)
    {
        switch (type)
        {
        case "bool":
            return Sane.ValueType.BOOL;
        case "int":
            return Sane.ValueType.INT;
        case "fixed":
            return Sane.ValueType.FIXED;
        case "string":
            return Sane.ValueType.STRING;
        case "button":
            return Sane.ValueType.BUTTON;
        default:
            return Sane.ValueType.GROUP;
        }
    }

    private static Sane.Unit unit_of (string? unit)
    {
        switch (unit)
        {
        case "pixel":
            return Sane.Unit.PIXEL;
        case "bit":
            return Sane.Unit.BIT;
        case "mm":
            return Sane.Unit.MM;
        case "dpi":
            return Sane.Unit.DPI;
        case "percent":
            return Sane.Unit.PERCENT;
        case "microsecond":
            return Sane.Unit.MICROSECOND;
        default:
            return Sane.Unit.NONE;
        }
    }

    /* A number as SANE carries it for the option's type */
    private static Sane.Word word_of (Sane.ValueType type, double value)
    {
        if (type == Sane.ValueType.FIXED)
            return (Sane.Word) Sane.FIX (value);
        return (Sane.Word) (int) Math.round (value);
    }

    private static ScanOption option_of (Variant d)
    {
        var option = new ScanOption ();
        var name = dict_string (d, "name");
        option.name = (name == null || name == "") ? null : name;
        option.title = dict_string (d, "title");
        option.desc = dict_string (d, "description");
        option.type = type_of (dict_string (d, "type"));
        option.unit = unit_of (dict_string (d, "unit"));
        var size = d.lookup_value ("size", VariantType.UINT32);
        option.size = (Sane.Int) (size != null ? (int) size.get_uint32 () : 1);
        option.cap = cap_of (d);

        /* Strings need room for the value and the terminator, as in SANE */
        if (option.type == Sane.ValueType.STRING)
            option.size = (Sane.Int) 256;
        else if (option.type == Sane.ValueType.INT || option.type == Sane.ValueType.FIXED || option.type == Sane.ValueType.BOOL)
            option.size = (Sane.Int) 4;

        var constraint = d.lookup_value ("constraint", null);
        if (constraint == null)
            return option;
        var kind = constraint.get_child_value (0).get_string ();
        var data = constraint.get_child_value (1).get_variant ();

        if (kind == "range")
        {
            double min, max, step;
            data.get ("(ddd)", out min, out max, out step);
            option.constraint_type = Sane.ConstraintType.RANGE;
            option.range = new ScanRange ();
            option.range.min = word_of (option.type, min);
            option.range.max = word_of (option.type, max);
            option.range.quant = word_of (option.type, step);
        }
        else if (kind == "list" && option.type == Sane.ValueType.STRING)
        {
            option.constraint_type = Sane.ConstraintType.STRING_LIST;
            var n = (int) data.n_children ();
            option.string_list = new string[n + 1];
            for (var i = 0; i < n; i++)
                option.string_list[i] = data.get_child_value (i).get_string ();
        }
        else if (kind == "list")
        {
            option.constraint_type = Sane.ConstraintType.WORD_LIST;
            var n = (int) data.n_children ();
            option.word_list = new Sane.Word[n + 1];
            option.word_list[0] = (Sane.Word) n;
            for (var i = 0; i < n; i++)
            {
                var v = data.get_child_value (i);
                option.word_list[i + 1] = word_of (option.type, v.is_of_type (VariantType.DOUBLE) ? v.get_double () : (double) v.get_int32 ());
            }
        }
        return option;
    }

    private Sane.Status fetch_options ()
    {
        try
        {
            var reply = call ("GetOptions", new Variant ("(o@a{sv})", session, empty_dict ()));
            var descriptors = reply.get_child_value (0);
            var n = (int) descriptors.n_children ();
            options = new ScanOption[n];
            for (var i = 0; i < n; i++)
                options[i] = option_of (descriptors.get_child_value (i));
            options_stale = false;
            return Sane.Status.GOOD;
        }
        catch (Error e)
        {
            warning ("Unable to get options: %s", e.message);
            return status_of_error (e);
        }
    }

    public ScanOption? get_option_descriptor (Sane.Int index)
    {
        if (options == null)
            return null;

        /* SANE's option 0 is the number of options. The portal leaves it out, so its options start at 1 */
        if (index == 0)
        {
            var count = new ScanOption ();
            count.title = "Number of options";
            count.type = Sane.ValueType.INT;
            count.size = (Sane.Int) 4;
            count.cap = (Sane.Int) Sane.Capability.SOFT_DETECT;
            return count;
        }

        if (options_stale)
            fetch_options ();

        if (index < 0 || (int) index > options.length)
            return null;
        return options[(int) index - 1];
    }

    public Sane.Status control_option (Sane.Int index, Sane.Action action, void *value)
    {
        if (options == null || index < 1 || (int) index > options.length)
            return Sane.Status.INVAL;
        var option = options[(int) index - 1];

        switch (action)
        {
        case Sane.Action.SET_AUTO:
            return send_option (option, auto_value (), null);
        case Sane.Action.GET_VALUE:
            return get_value (option, value);
        default:
            return set_value (option, value);
        }
    }

    /* SetOptions takes this in place of a value to pick the option's own */
    private static Variant auto_value ()
    {
        var auto = new VariantBuilder (new VariantType ("a{sv}"));
        auto.add ("{sv}", "auto", new Variant.boolean (true));
        return auto.end ();
    }

    private Sane.Status get_value (ScanOption option, void *value)
    {
        try
        {
            var reply = call ("GetOptionValues", new Variant ("(o@a{sv})", session, empty_dict ()));
            var v = reply.get_child_value (0).lookup_value (option.name, null);
            if (v == null)
                return Sane.Status.INVAL;
            store_value (option, v, value);
            return Sane.Status.GOOD;
        }
        catch (Error e)
        {
            warning ("Unable to get option %s: %s", option.name, e.message);
            return status_of_error (e);
        }
    }

    /* Put a value from the portal where SANE's caller expects it */
    private static void store_value (ScanOption option, Variant v, void *value)
    {
        switch (option.type)
        {
        case Sane.ValueType.BOOL:
            *((Sane.Bool*) value) = (Sane.Bool) v.get_boolean ();
            break;
        case Sane.ValueType.INT:
            *((Sane.Int*) value) = (Sane.Int) (v.is_of_type (VariantType.DOUBLE) ? (int) v.get_double () : v.get_int32 ());
            break;
        case Sane.ValueType.FIXED:
            *((Sane.Fixed*) value) = Sane.FIX (v.is_of_type (VariantType.DOUBLE) ? v.get_double () : (double) v.get_int32 ());
            break;
        case Sane.ValueType.STRING:
            var s = v.get_string ();
            var buffer = (char*) value;
            var i = 0;
            for (; i < (int) option.size - 1 && s[i] != '\0'; i++)
                buffer[i] = s[i];
            buffer[i] = '\0';
            break;
        default:
            break;
        }
    }

    private Sane.Status set_value (ScanOption option, void *value)
    {
        Variant v;
        switch (option.type)
        {
        case Sane.ValueType.BOOL:
            v = new Variant.boolean ((bool) *((Sane.Bool*) value));
            break;
        case Sane.ValueType.INT:
            v = new Variant.int32 ((int) *((Sane.Int*) value));
            break;
        case Sane.ValueType.FIXED:
            v = new Variant.double (Sane.UNFIX (*((Sane.Fixed*) value)));
            break;
        case Sane.ValueType.STRING:
            v = new Variant.string ((string) value);
            break;
        case Sane.ValueType.BUTTON:
            v = new Variant.boolean (true);
            break;
        default:
            return Sane.Status.INVAL;
        }

        return send_option (option, v, value);
    }

    /* Set an option, and put the value it ended up with where SANE's caller expects it */
    private Sane.Status send_option (ScanOption option, Variant v, void *value)
    {
        try
        {
            var values = new VariantBuilder (new VariantType ("a(sv)"));
            values.add ("(sv)", option.name, v);
            var reply = call ("SetOptions", new Variant ("(o@a(sv)@a{sv})", session, values.end (), empty_dict ()));

            var applied = reply.get_child_value (0).lookup_value (option.name, null);
            if (applied != null && value != null)
                store_value (option, applied, value);

            /* Other options may have changed: read them again before they are looked at */
            foreach (var f in reply.get_child_value (1).get_strv ())
            {
                if (f == "reload-options")
                    options_stale = true;
            }
            return Sane.Status.GOOD;
        }
        catch (Error e)
        {
            warning ("Unable to set option %s: %s", option.name, e.message);
            return status_of_error (e);
        }
    }

    /* Frames */

    private Sane.Status status_of_event (Event event)
    {
        switch (event.state)
        {
        case "cancelled":
            return Sane.Status.CANCELLED;
        case "no-documents":
            return Sane.Status.NO_DOCS;
        default:
            var message = dict_string (event.details, "message");
            var code = dict_string (event.details, "code");
            warning ("Scan failed: %s (%s)", message ?? "no message", code ?? "no code");
            if (code == "org.freedesktop.portal.Error.Busy")
                return Sane.Status.DEVICE_BUSY;
            return Sane.Status.IO_ERROR;
        }
    }

    public Sane.Status start ()
    {
        if (session == null)
            return Sane.Status.INVAL;

        while (frame_events.try_pop () != null);

        UnixFDList fds;
        try
        {
            var reply = bus.call_with_unix_fd_list_sync (bus_name, PORTAL_PATH, SCANNER_IFACE, "StartFrame",
                                                         new Variant ("(o@a{sv})", session, empty_dict ()),
                                                         new VariantType ("(h)"), DBusCallFlags.NONE, CALL_TIMEOUT_MS,
                                                         null, out fds);
            pipe_fd = fds.get (reply.get_child_value (0).get_handle ());
        }
        catch (Error e)
        {
            warning ("Unable to start a frame: %s", e.message);
            return status_of_error (e);
        }
        frame_running = true;

        var event = next_event (START_TIMEOUT_US);
        if (event == null)
        {
            warning ("The scanner did not start");
            cancel ();
            return Sane.Status.IO_ERROR;
        }
        if (event.state != "started")
        {
            frame_running = false;
            Posix.close (pipe_fd);
            pipe_fd = -1;
            return status_of_event (event);
        }

        var d = event.details;
        var format = dict_string (d, "format");
        switch (format)
        {
        case "rgb":
            parameters.format = Sane.Frame.RGB;
            break;
        case "red":
            parameters.format = Sane.Frame.RED;
            break;
        case "green":
            parameters.format = Sane.Frame.GREEN;
            break;
        case "blue":
            parameters.format = Sane.Frame.BLUE;
            break;
        default:
            parameters.format = Sane.Frame.GRAY;
            break;
        }
        parameters.depth = (int) d.lookup_value ("depth", VariantType.UINT32).get_uint32 ();
        parameters.pixels_per_line = (int) d.lookup_value ("pixels_per_line", VariantType.UINT32).get_uint32 ();
        parameters.bytes_per_line = (int) d.lookup_value ("bytes_per_line", VariantType.UINT32).get_uint32 ();
        parameters.lines = d.lookup_value ("lines", VariantType.INT32).get_int32 ();
        parameters.last_frame = d.lookup_value ("last_frame", VariantType.BOOLEAN).get_boolean ();
        return Sane.Status.GOOD;
    }

    public Sane.Status get_parameters (out Sane.Parameters p)
    {
        p = parameters;
        return frame_running ? Sane.Status.GOOD : Sane.Status.INVAL;
    }

    public Sane.Status read (uint8* data, Sane.Int max_length, out Sane.Int length)
    {
        length = 0;
        if (pipe_fd < 0)
            return Sane.Status.INVAL;

        ssize_t n = 0;
        do
            n = Posix.read (pipe_fd, data, (size_t) max_length);
        while (n < 0 && errno == Posix.EINTR);

        if (n > 0)
        {
            length = (Sane.Int) n;
            return Sane.Status.GOOD;
        }
        if (n < 0)
        {
            warning ("Unable to read the frame: %s", strerror (errno));
            return Sane.Status.IO_ERROR;
        }

        /* The pipe ending is not the end of the frame: the portal says how it went */
        Posix.close (pipe_fd);
        pipe_fd = -1;
        var event = next_event (FINISH_TIMEOUT_US);
        frame_running = false;
        if (event == null)
        {
            warning ("The scanner did not say it was finished");
            return Sane.Status.IO_ERROR;
        }
        if (event.state == "finished")
            return Sane.Status.EOF;
        return status_of_event (event);
    }
}
