/*
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

/* What Scanner needs to know about a scan device. */
public class ScanDeviceInfo
{
    public string name;
    public string vendor;
    public string model;
    public string type;
}

public class ScanRange
{
    public Sane.Word min;
    public Sane.Word max;
    public Sane.Word quant;
}

/* An option as the scan thread sees it. It has the shape of a SANE option descriptor, so the
 * code that picks and sets options is the same for every backend. Fixed point values are
 * SANE_FIX () words, and word_list[0] is the number of entries that follow, as in SANE. */
public class ScanOption
{
    public string? name;
    public string? title;
    public string? desc;
    public Sane.ValueType type;
    public Sane.Unit unit;
    public Sane.Int size;
    public Sane.Int cap;

    public Sane.ConstraintType constraint_type;
    public string[]? string_list;
    public Sane.Word[]? word_list;
    public ScanRange? range;
}

/* The part of SANE that Scanner uses, so that it can be provided by libsane or by the scanner
 * portal. The calls and the status codes are SANE's, which keeps Scanner's logic unchanged. */
public interface ScanBackend : Object
{
    public abstract bool init ();
    public abstract void exit ();

    public abstract Sane.Status get_devices (out ScanDeviceInfo?[] devices);

    /* Let the user choose which scanners the application may use, for backends that have such a choice */
    public abstract bool select_devices ();

    public abstract Sane.Status open (string device);
    public abstract void close ();
    public abstract void cancel ();

    public abstract ScanOption? get_option_descriptor (Sane.Int index);
    public abstract Sane.Status control_option (Sane.Int index, Sane.Action action, void *value);

    public abstract Sane.Status start ();
    public abstract Sane.Status get_parameters (out Sane.Parameters parameters);
    public abstract Sane.Status read (uint8* data, Sane.Int max_length, out Sane.Int length);
}
