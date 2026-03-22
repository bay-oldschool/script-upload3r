#!/usr/bin/env pwsh
# Modern Explorer-style folder picker using IFileOpenDialog COM with FOS_PICKFOLDERS.
# Outputs selected folder path to stdout, or empty string if cancelled.
param([string]$title = 'Select folder')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
internal class FileOpenDialogRCW { }

[ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IFileOpenDialog {
    [PreserveSig] int Show([In] IntPtr hwnd);
    void SetFileTypes();
    void SetFileTypeIndex();
    void GetFileTypeIndex();
    void Advise();
    void Unadvise();
    void SetOptions([In] uint fos);
    void GetOptions(out uint fos);
    void SetDefaultFolder();
    void SetFolder();
    void GetFolder();
    void GetCurrentSelection();
    void SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetFileName();
    void SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
    void SetOkButtonLabel();
    void SetFileNameLabel();
    int GetResult(out IShellItem ppsi);
}

[ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellItem {
    void BindToHandler();
    void GetParent();
    int GetDisplayName([In] uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
}

public static class FolderPicker {
    public static string Show(string title) {
        var dlg = (IFileOpenDialog)new FileOpenDialogRCW();
        // FOS_PICKFOLDERS = 0x20, FOS_FORCEFILESYSTEM = 0x40
        dlg.SetOptions(0x20 | 0x40);
        dlg.SetTitle(title);
        int hr = dlg.Show(IntPtr.Zero);
        if (hr != 0) return "";
        IShellItem item;
        dlg.GetResult(out item);
        string path;
        item.GetDisplayName(0x80058000, out path); // SIGDN_FILESYSPATH
        return path;
    }
}
'@

$result = [FolderPicker]::Show($title)
if ($result) { Write-Output $result } else { Write-Output '' }
