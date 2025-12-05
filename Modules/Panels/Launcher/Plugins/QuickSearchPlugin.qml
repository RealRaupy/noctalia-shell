import QtQuick
import Quickshell
import qs.Commons

Item {
  property var launcher: null
  property string name: I18n.tr("plugins.quicksearch")
  property bool handleSearch: true

  function iconPath(name) {
    const base = (typeof Quickshell !== "undefined" && Quickshell.shellDir) ? Quickshell.shellDir : "";
    return base ? `file://${base}/Assets/Icons/QuickSearch/${name}.svg` : "";
  }

  // Available quicksearch targets
  property var searchEngines: [
    {
      "keywords": ["g", "google"],
      "displayName": "Google",
      "searchUrl": "https://www.google.com/search?q={query}",
      "homeUrl": "https://www.google.com",
      "icon": iconPath("google")
    },
    {
      "keywords": ["ddg", "duckduckgo"],
      "displayName": "DuckDuckGo",
      "searchUrl": "https://duckduckgo.com/?q={query}",
      "homeUrl": "https://duckduckgo.com",
      "icon": iconPath("duckduckgo")
    },
    {
      "keywords": ["yt", "youtube"],
      "displayName": "YouTube",
      "searchUrl": "https://www.youtube.com/results?search_query={query}",
      "homeUrl": "https://www.youtube.com",
      "icon": iconPath("youtube")
    },
    {
      "keywords": ["tw", "twitter", "x"],
      "displayName": "Twitter (X)",
      "searchUrl": "https://twitter.com/search?q={query}",
      "homeUrl": "https://twitter.com",
      "icon": iconPath("twitter")
    },
    {
      "keywords": ["twitch", "ttv"],
      "displayName": "Twitch",
      "searchUrl": "https://www.twitch.tv/search?term={query}",
      "homeUrl": "https://www.twitch.tv",
      "icon": iconPath("twitch")
    },
    {
      "keywords": ["gh", "github"],
      "displayName": "GitHub",
      "searchUrl": "https://github.com/search?q={query}",
      "homeUrl": "https://github.com",
      "icon": iconPath("github")
    },
    {
      "keywords": ["so", "stackoverflow", "stack"],
      "displayName": "Stack Overflow",
      "searchUrl": "https://stackoverflow.com/search?q={query}",
      "homeUrl": "https://stackoverflow.com",
      "icon": iconPath("stackoverflow")
    },
    {
      "keywords": ["r", "reddit"],
      "displayName": "Reddit",
      "searchUrl": "https://www.reddit.com/search/?q={query}",
      "homeUrl": "https://www.reddit.com",
      "icon": iconPath("reddit")
    },
    {
      "keywords": ["mdn"],
      "displayName": "MDN",
      "searchUrl": "https://developer.mozilla.org/en-US/search?q={query}",
      "homeUrl": "https://developer.mozilla.org",
      "icon": iconPath("mdn")
    },
    {
      "keywords": ["npm"],
      "displayName": "npm",
      "searchUrl": "https://www.npmjs.com/search?q={query}",
      "homeUrl": "https://www.npmjs.com",
      "icon": iconPath("npm")
    },
    {
      "keywords": ["aur"],
      "displayName": "AUR",
      "searchUrl": "https://aur.archlinux.org/packages?K={query}",
      "homeUrl": "https://aur.archlinux.org",
      "icon": iconPath("aur")
    },
    {
      "keywords": ["arch", "archwiki", "aw"],
      "displayName": "Arch Wiki",
      "searchUrl": "https://wiki.archlinux.org/index.php?search={query}",
      "homeUrl": "https://wiki.archlinux.org",
      "icon": iconPath("archwiki")
    },
    {
      "keywords": ["w", "wiki", "wikipedia"],
      "displayName": "Wikipedia",
      "searchUrl": "https://en.wikipedia.org/w/index.php?search={query}",
      "homeUrl": "https://en.wikipedia.org",
      "icon": iconPath("wikipedia")
    }
  ]

  function getResults(searchText) {
    if (!searchText || !searchText.startsWith("!")) {
      return [];
    }

    const trimmed = searchText.substring(1).trim();

    if (!trimmed) {
      return searchEngines.map(engine => createHintEntry(engine));
    }

    const parts = trimmed.split(/\s+/);
    const shortcut = (parts.shift() || "").toLowerCase();
    const query = parts.join(" ").trim();
    const engine = findEngine(shortcut);

    if (!engine) {
      return [unknownShortcutEntry(shortcut)];
    }

    return [createSearchEntry(engine, query)];
  }

  function createHintEntry(engine) {
    const shortcut = primaryKeyword(engine);
    return {
      "name": `!${shortcut} — ${engine.displayName}`,
      "description": I18n.tr("plugins.quicksearch-hint", { "shortcut": shortcut, "target": engine.displayName }),
      "icon": engine.icon || "internet-web-browser",
      "isImage": false,
      "onActivate": function () {
        if (shortcut) {
          launcher.setSearchText(`!${shortcut} `);
        }
      }
    };
  }

  function unknownShortcutEntry(shortcut) {
    const available = searchEngines.map(engine => `!${primaryKeyword(engine)}`).join(", ");
    return {
      "name": I18n.tr("plugins.quicksearch-unknown", { "shortcut": shortcut }),
      "description": `${I18n.tr("plugins.quicksearch-available")}: ${available}`,
      "icon": "internet-web-browser",
      "isImage": false,
      "onActivate": function () {
        launcher.setSearchText("!");
      }
    };
  }

  function createSearchEntry(engine, query) {
    const shortcut = primaryKeyword(engine);
    const targetName = engine.displayName;
    const hasQuery = query && query.length > 0;
    const url = buildUrl(engine, query);
    const hasHome = !!engine.homeUrl;
    return {
      "name": hasQuery ? `${targetName}: ${query}` : targetName,
      "description": hasQuery
          ? I18n.tr("plugins.quicksearch-open")
          : I18n.tr("plugins.quicksearch-enter-or-home", { "shortcut": shortcut, "target": targetName }),
      "icon": engine.icon || "internet-web-browser",
      "isImage": false,
      "onActivate": function () {
        const opened = !!url;
        if (opened) {
          Quickshell.execDetached(["xdg-open", url]);
        }
        if (hasQuery || hasHome || opened) {
          launcher.close();
          return;
        }

        // No homepage: just prep the query input
        launcher.setSearchText(`!${shortcut} `);
      }
    };
  }

  function buildUrl(engine, query) {
    const encoded = encodeURIComponent(query || "");

    if (!query && engine.homeUrl) {
      return engine.homeUrl;
    }

    if (engine.searchUrl) {
      return engine.searchUrl.replace("{query}", encoded);
    }

    return "";
  }

  function findEngine(shortcut) {
    const lower = (shortcut || "").toLowerCase();
    for (let engine of searchEngines) {
      if ((engine.keywords || []).some(k => k.toLowerCase() === lower)) {
        return engine;
      }
    }
    return null;
  }

  function primaryKeyword(engine) {
    if (engine && engine.keywords && engine.keywords.length > 0) {
      return engine.keywords[0];
    }
    return "";
  }
}
