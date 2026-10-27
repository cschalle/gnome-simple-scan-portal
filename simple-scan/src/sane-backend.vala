/*
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

/* libsane, loaded in the application. */
public class SaneBackend : Object, ScanBackend
{
    private Sane.Handle handle;

    public bool init ()
    {
        Sane.Int version_code;
        var status = Sane.init (out version_code, Scanner.authorization_cb);
        debug ("sane_init () -> %s", Sane.status_to_string (status));
        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to initialize SANE backend: %s", Sane.strstatus (status));
            return false;
        }
        debug ("SANE version %d.%d.%d",
               Sane.VERSION_MAJOR (version_code),
               Sane.VERSION_MINOR (version_code),
               Sane.VERSION_BUILD (version_code));
        return true;
    }

    public void exit ()
    {
        Sane.exit ();
        debug ("sane_exit ()");
    }

    public bool select_devices ()
    {
        return false;
    }

    public Sane.Status get_devices (out ScanDeviceInfo?[] devices)
    {
        unowned Sane.Device[] device_list = null;
        var status = Sane.get_devices (out device_list, false);
        debug ("sane_get_devices () -> %s", Sane.status_to_string (status));

        var n = 0;
        if (status == Sane.Status.GOOD)
            while (device_list[n] != null)
                n++;
        devices = new ScanDeviceInfo?[n + 1];
        for (var i = 0; i < n; i++)
        {
            var info = new ScanDeviceInfo ();
            info.name = device_list[i].name;
            info.vendor = device_list[i].vendor;
            info.model = device_list[i].model;
            info.type = device_list[i].type;
            devices[i] = info;
        }
        return status;
    }

    public Sane.Status open (string device)
    {
        var status = Sane.open (device, out handle);
        debug ("sane_open (\"%s\") -> %s", device, Sane.status_to_string (status));
        return status;
    }

    public void close ()
    {
        Sane.close (handle);
        debug ("sane_close ()");
    }

    public void cancel ()
    {
        Sane.cancel (handle);
        debug ("sane_cancel ()");
    }

    public ScanOption? get_option_descriptor (Sane.Int index)
    {
        var d = Sane.get_option_descriptor (handle, index);
        if (d == null)
            return null;

        var option = new ScanOption ();
        option.name = d.name;
        option.title = d.title;
        option.desc = d.desc;
        option.type = d.type;
        option.unit = d.unit;
        option.size = d.size;
        option.cap = d.cap;
        option.constraint_type = d.constraint_type;
        switch (d.constraint_type)
        {
        case Sane.ConstraintType.RANGE:
            option.range = new ScanRange ();
            option.range.min = d.range.min;
            option.range.max = d.range.max;
            option.range.quant = d.range.quant;
            break;
        case Sane.ConstraintType.WORD_LIST:
            var n = (int) d.word_list[0];
            option.word_list = new Sane.Word[n + 1];
            for (var i = 0; i <= n; i++)
                option.word_list[i] = d.word_list[i];
            break;
        case Sane.ConstraintType.STRING_LIST:
            var n = 0;
            while (d.string_list[n] != null)
                n++;
            option.string_list = new string[n + 1];
            for (var i = 0; i < n; i++)
                option.string_list[i] = d.string_list[i];
            break;
        default:
            break;
        }
        return option;
    }

    public Sane.Status control_option (Sane.Int index, Sane.Action action, void *value)
    {
        return Sane.control_option (handle, index, action, value, null);
    }

    public Sane.Status start ()
    {
        var status = Sane.start (handle);
        return status;
    }

    public Sane.Status get_parameters (out Sane.Parameters parameters)
    {
        var status = Sane.get_parameters (handle, out parameters);
        debug ("sane_get_parameters () -> %s", Sane.status_to_string (status));
        return status;
    }

    public Sane.Status read (uint8* data, Sane.Int max_length, out Sane.Int length)
    {
        return Sane.read (handle, data, max_length, out length);
    }
}
