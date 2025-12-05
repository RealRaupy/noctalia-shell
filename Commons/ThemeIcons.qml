pragma Singleton

import QtQuick
import Quickshell

Singleton {
  id: root

  function iconFromName(iconName, fallbackName) {
    const fallback = fallbackName || "application-x-executable";

    // If we already have a concrete file/URL, return it directly so we don't lose icons with absolute paths.
    if (iconName) {
      const lower = iconName.toLowerCase();
      if (lower.startsWith("file://") || lower.startsWith("qrc:/") || lower.startsWith("data:") || lower.startsWith("image://"))
        return iconName;

      // Handle absolute paths from .desktop files (including ~ and Windows-style paths)
      if (iconName.startsWith("/") || iconName.startsWith("~") || /^[A-Za-z]:[\\/]/.test(iconName)) {
        const expanded = (iconName.startsWith("~") && typeof Quickshell !== "undefined" && Quickshell.env)
            ? iconName.replace(/^~/, Quickshell.env("HOME") || "~")
            : iconName;
        const normalized = expanded.replace(/\\/g, "/");
        return normalized.startsWith("file://") ? normalized : `file://${normalized}`;
      }
    }

    try {
      if (iconName && typeof Quickshell !== 'undefined' && Quickshell.iconPath) {
        const p = Quickshell.iconPath(iconName, fallback);
        if (p && p !== "")
          return p;
      }
    } catch (e)

      // ignore and fall back
    {}
    try {
      return Quickshell.iconPath ? (Quickshell.iconPath(fallback, true) || "") : "";
    } catch (e2) {
      return "";
    }
  }

  // Resolve icon path for a DesktopEntries appId - safe on missing entries
  function iconForAppId(appId, fallbackName) {
    const fallback = fallbackName || "application-x-executable";
    if (!appId)
      return iconFromName(fallback, fallback);
    try {
      if (typeof DesktopEntries === 'undefined' || !DesktopEntries.byId)
        return iconFromName(fallback, fallback);
      const entry = (DesktopEntries.heuristicLookup) ? DesktopEntries.heuristicLookup(appId) : DesktopEntries.byId(appId);
      const name = entry && entry.icon ? entry.icon : "";
      return iconFromName(name || fallback, fallback);
    } catch (e) {
      return iconFromName(fallback, fallback);
    }
  }

  // Distro logo helper (absolute path or empty string)
  function distroLogoPath() {
    try {
      return (typeof OSInfo !== 'undefined' && OSInfo.distroIconPath) ? OSInfo.distroIconPath : "";
    } catch (e) {
      return "";
    }
  }
}
