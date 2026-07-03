#!/bin/bash
#
# uninstall-openvpn-connect.sh
# Completely remove the OpenVPN Connect macOS app and all of its
# configuration, caches, logs, launch services, Dock icon and extension
# leftovers.
#
# Run as your normal user (NOT with sudo). The script calls sudo itself
# for the system-level paths and will prompt for your password once.
#
# NOTE (bug fix): OpenVPN Connect for macOS is shipped as a PKG that
# installs into a ROOT-OWNED folder "/Applications/OpenVPN Connect/"
# (containing the app plus its own "Uninstall OpenVPN Connect.app").
# An earlier version of this script tried to delete that folder as the
# normal user and failed with "Permission denied" on every file. The
# application is now removed with sudo (see step 3).
#
# Idempotent: safe to run repeatedly; it only touches things that exist.

set -u

echo "════════════════════════════════════════════════════════"
echo " OpenVPN Connect — complete uninstall"
echo "════════════════════════════════════════════════════════"

if [ "$(id -u)" -eq 0 ]; then
  echo "Please run this as your normal user, not with sudo."
  echo "(It will call sudo itself only where needed.)"
  exit 1
fi

read -r -p "This permanently deletes OpenVPN Connect and its data. Continue? [y/N] " reply
case "$reply" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
rm_user() {   # remove a user-owned path
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    echo "  removing        : $p"
    rm -rf "$p"
  fi
}

rm_sys() {    # remove a system / root-owned path (needs sudo)
  local p="$1"
  if sudo test -e "$p" 2>/dev/null; then
    echo "  removing (sudo) : $p"
    sudo rm -rf "$p"
  fi
}

rm_glob_user() {  # remove user paths matching a case-insensitive name pattern in a dir
  local dir="$1" pattern="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -iname "$pattern" -print0 2>/dev/null |
    while IFS= read -r -d '' p; do
      echo "  removing        : $p"
      rm -rf "$p"
    done
}

rm_glob_sys() {   # remove system paths matching a pattern in a dir (needs sudo)
  local dir="$1" pattern="$2"
  sudo test -d "$dir" 2>/dev/null || return 0
  sudo find "$dir" -maxdepth 1 -iname "$pattern" -print0 2>/dev/null |
    while IFS= read -r -d '' p; do
      echo "  removing (sudo) : $p"
      sudo rm -rf "$p"
    done
}

# Remove any OpenVPN tile from the Dock (the leftover icon after uninstall).
dock_remove_openvpn() {
  local plist="$HOME/Library/Preferences/com.apple.dock.plist"
  [ -f "$plist" ] || { echo "  no Dock preferences found"; return 0; }
  command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || {
    echo "  PlistBuddy unavailable; skipping Dock cleanup"; return 0; }

  # Count entries in persistent-apps.
  local n=0
  while /usr/libexec/PlistBuddy -c "Print persistent-apps:$n" "$plist" >/dev/null 2>&1; do
    n=$((n + 1))
  done

  # Find matching tiles first, scanning from the end so the indices we record
  # stay valid when we delete (deleting an entry renumbers everything after it).
  local matches=() i url
  for (( i = n - 1; i >= 0; i-- )); do
    url=$(/usr/libexec/PlistBuddy -c \
      "Print persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null)
    case "$url" in
      *[Oo][Pp][Ee][Nn][Vv][Pp][Nn]*) matches+=("$i") ;;
    esac
  done

  if [ "${#matches[@]}" -eq 0 ]; then
    echo "  no OpenVPN icon in the Dock"
    return 0
  fi

  # Stop cfprefsd BEFORE editing so it can't flush its stale in-memory copy of
  # the Dock prefs back over our on-disk change; it re-reads from disk when it
  # respawns on next access.
  killall cfprefsd 2>/dev/null || true

  local removed=0
  for i in "${matches[@]}"; do
    if /usr/libexec/PlistBuddy -c "Delete persistent-apps:$i" "$plist" 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done

  echo "  removed $removed OpenVPN icon(s) from the Dock"
  killall Dock 2>/dev/null || true   # reload the Dock so the tile disappears
}

# ----------------------------------------------------------------------
# 1. Quit the running app and any helper processes
# ----------------------------------------------------------------------
echo
echo "[1/7] Stopping OpenVPN Connect..."
osascript -e 'tell application "OpenVPN Connect" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -f "OpenVPN Connect" 2>/dev/null || true
pkill -x "OpenVPNConnect"  2>/dev/null || true
pkill -f "ovpnhelper"      2>/dev/null || true
pkill -x "openvpn"         2>/dev/null || true

# ----------------------------------------------------------------------
# 2. Unload launch daemons / agents, then remove them
# ----------------------------------------------------------------------
echo
echo "[2/7] Removing launch services..."
for plist in \
  /Library/LaunchDaemons/org.openvpn.*.plist \
  /Library/LaunchDaemons/net.openvpn.*.plist \
  /Library/LaunchDaemons/com.openvpn.*.plist \
  /Library/LaunchDaemons/*OpenVPN*.plist \
  "$HOME"/Library/LaunchAgents/org.openvpn.*.plist \
  "$HOME"/Library/LaunchAgents/net.openvpn.*.plist \
  "$HOME"/Library/LaunchAgents/*OpenVPN*.plist ; do
  # globs that don't match expand literally; skip those
  case "$plist" in *'*'*) continue ;; esac
  echo "  unloading       : $plist"
  sudo launchctl unload "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
done
rm_glob_sys  /Library/LaunchDaemons         "org.openvpn.*"
rm_glob_sys  /Library/LaunchDaemons         "net.openvpn.*"
rm_glob_sys  /Library/LaunchDaemons         "com.openvpn.*"
rm_glob_sys  /Library/LaunchDaemons         "*OpenVPN*"
rm_glob_sys  /Library/LaunchAgents          "*openvpn*"
rm_glob_user "$HOME/Library/LaunchAgents"   "*openvpn*"
rm_glob_sys  /Library/PrivilegedHelperTools "*openvpn*"

# ----------------------------------------------------------------------
# 3. Remove the application bundle (root-owned — needs sudo)
# ----------------------------------------------------------------------
echo
echo "[3/7] Removing the application..."
# PKG install: a root-owned folder holding the app + its uninstaller.
rm_sys  "/Applications/OpenVPN Connect"
# Drag install: a standalone bundle directly in /Applications.
rm_sys  "/Applications/OpenVPN Connect.app"

# ----------------------------------------------------------------------
# 4. Remove the leftover Dock icon
# ----------------------------------------------------------------------
echo
echo "[4/7] Removing the Dock icon..."
dock_remove_openvpn

# ----------------------------------------------------------------------
# 5. Remove user-level configuration, caches, logs, containers
# ----------------------------------------------------------------------
echo
echo "[5/7] Removing user configuration & data..."
rm_user "$HOME/Library/Application Support/OpenVPN Connect"
rm_user "$HOME/Library/Application Support/OpenVPN"
rm_user "$HOME/Library/Logs/OpenVPN Connect"
rm_user "$HOME/Library/Logs/OpenVPN"
rm_glob_user "$HOME/Library/Preferences"             "*openvpn*"
rm_glob_user "$HOME/Library/Caches"                  "*openvpn*"
rm_glob_user "$HOME/Library/HTTPStorages"            "*openvpn*"
rm_glob_user "$HOME/Library/Containers"              "*openvpn*"
rm_glob_user "$HOME/Library/Group Containers"        "*openvpn*"
rm_glob_user "$HOME/Library/Saved Application State" "*openvpn*"
rm_glob_user "$HOME/Library/WebKit"                  "*openvpn*"

# ----------------------------------------------------------------------
# 6. Remove system-level leftovers
# ----------------------------------------------------------------------
echo
echo "[6/7] Removing system-level leftovers..."
rm_sys "/Library/Application Support/OpenVPN"
rm_sys "/Library/Application Support/OpenVPN Connect"
rm_glob_sys "/Library/Logs" "*openvpn*"
rm_sys "/var/log/openvpn"

# ----------------------------------------------------------------------
# 7. System extension (cannot be force-removed without SIP off)
# ----------------------------------------------------------------------
echo
echo "[7/7] Checking for a registered system extension..."
if command -v systemextensionsctl >/dev/null 2>&1; then
  if systemextensionsctl list 2>/dev/null | grep -i openvpn >/dev/null; then
    echo "  A macOS system extension from OpenVPN is still registered:"
    systemextensionsctl list 2>/dev/null | grep -i openvpn | sed 's/^/    /'
    echo "  macOS removes an orphaned extension automatically after its app is"
    echo "  gone — a reboot finalizes this. (Forcing it now would require"
    echo "  disabling SIP, which is not worth doing.)"
  else
    echo "  No OpenVPN system extension registered. Good."
  fi
else
  echo "  systemextensionsctl not available; skipping."
fi

echo
echo "════════════════════════════════════════════════════════"
echo " Done."
echo
echo " Manual step: open  System Settings → VPN  (and"
echo " System Settings → General → Login Items & Extensions →"
echo " Network Extensions) and delete any leftover 'OpenVPN'"
echo " entry if one remains."
echo
echo " Then REBOOT to clear the system extension, and proceed"
echo " with the openvpn CLI:"
echo "   ./install-openvpn-cli.sh"
echo "════════════════════════════════════════════════════════"
