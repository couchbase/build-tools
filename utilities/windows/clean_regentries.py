import sys
import winreg

# Quick and dirty script to delete registry entries for files
# from broken/incompletely-removed Server installations

hklm = winreg.ConnectRegistry(None, winreg.HKEY_LOCAL_MACHINE)

installer = winreg.OpenKey(
    hklm, "SOFTWARE\Microsoft\Windows\CurrentVersion\Installer"
)

prefix = "C:\\Program Files\Couchbase"

# First clean up folders
folders = winreg.OpenKey(installer, "Folders", access=winreg.KEY_ALL_ACCESS)
_, num_folders, _ = winreg.QueryInfoKey(folders)
print ("Iterating through Installer\\Folders...")
for i in range(num_folders-1, -1, -1):
    value, data, _ = winreg.EnumValue(folders, i)
    if value.startswith(prefix):
        print(f"Deleting {value}")
        winreg.DeleteValue(folders, value)

winreg.CloseKey(folders)
print()

# Now files. User "S-1-5-18" is the Administrator user, because sure, why not.
components = winreg.OpenKey(
    installer,
    "UserData\\S-1-5-18\\Components",
    access=winreg.KEY_ALL_ACCESS
)
num_components, foo_, bar_ = winreg.QueryInfoKey(components)
print ("Iterating through Installer\\UserData\\S-1-5-18\\Components...")
for i in range(num_components-1, -1, -1):
    component_name = winreg.EnumKey(components, i)
    component = winreg.OpenKey(components, component_name)

    # Here we want to verify that ALL product codes in this key reference
    # our prefix. Don't delete the key if not.
    _, num_values, _ = winreg.QueryInfoKey(component)
    prefix_found = False
    for i in range(num_values-1, -1, -1):
        value, data, type_ = winreg.EnumValue(component, i)
        if type_ != winreg.REG_SZ:
            continue
        if data.startswith(prefix):
            prefix_found = True
        elif prefix_found == True:
            print(f"Help! non-prefix path and prefix path both found in component {component_name}")
            sys.exit(1)

    winreg.CloseKey(component)
    if prefix_found:
        print(f"Deleting {component_name}")
        winreg.DeleteKey(components, component_name)

winreg.CloseKey(components)
print("\nDone!")