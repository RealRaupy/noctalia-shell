import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root

  property string specificFolderMonitorName: ""
  
  // Use a persistent singleton-like state for steam check
  // This prevents rechecking every time the tab is opened
  readonly property QtObject steamState: QtObject {
    id: steamStateObj
    property int exitCode: -1 // -1 = not checked yet, 0 = available, 1 = not available
    property bool checkRunning: false
  }
  
  readonly property bool steamIntegrationAvailable: steamState.exitCode === 0

  function enforceSteamAvailability() {
    // Only disable steam integration if check is done AND failed
    if (steamState.exitCode === 1) { // Explicitly failed (not just unchecked)
      if (Settings.data.wallpaper.steamWallpaperIntegration) {
        Logger.d("WallpaperTab", "Steam not available, disabling integration");
        Settings.data.wallpaper.steamWallpaperIntegration = false;
      }
      if (Settings.data.wallpaper.useSteamWallpapers) {
        Settings.data.wallpaper.useSteamWallpapers = false;
      }
    }
  }

  Component.onCompleted: {
    // Only run check if not already done
    if (steamState.exitCode === -1 && !steamState.checkRunning) {
      steamState.checkRunning = true;
      steamCheck.running = true;
    }
  }

  Process {
    id: steamCheck
    command: [Quickshell.shellDir + "/Bin/check-steam-wallpaper.sh"]
    running: false
    onExited: function (exitCode) {
      Logger.d("WallpaperTab", "Steam check completed with exit code:", exitCode);
      steamState.exitCode = exitCode;
      steamState.checkRunning = false;
      enforceSteamAvailability();
    }
    stdout: StdioCollector {}
    stderr: StdioCollector {}
  }

  spacing: Style.marginL

  NHeader {
    label: I18n.tr("settings.wallpaper.settings.section.label")
    description: I18n.tr("settings.wallpaper.settings.section.description")
  }

  NToggle {
    label: I18n.tr("settings.wallpaper.settings.enable-management.label")
    description: I18n.tr("settings.wallpaper.settings.enable-management.description")
    checked: Settings.data.wallpaper.enabled
    onToggled: checked => Settings.data.wallpaper.enabled = checked
    Layout.bottomMargin: Style.marginL
  }

  NToggle {
    visible: Settings.data.wallpaper.enabled && CompositorService.isNiri
    label: I18n.tr("settings.wallpaper.settings.enable-overview.label")
    description: I18n.tr("settings.wallpaper.settings.enable-overview.description")
    checked: Settings.data.wallpaper.overviewEnabled
    onToggled: checked => Settings.data.wallpaper.overviewEnabled = checked
    Layout.bottomMargin: Style.marginL
  }

  NDivider {
    visible: Settings.data.wallpaper.enabled
    Layout.fillWidth: true
    Layout.topMargin: Style.marginL
    Layout.bottomMargin: Style.marginL
  }

  ColumnLayout {
    visible: Settings.data.wallpaper.enabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NTextInputButton {
      id: wallpaperPathInput
      label: I18n.tr("settings.wallpaper.settings.folder.label")
      description: I18n.tr("settings.wallpaper.settings.folder.description")
      text: Settings.data.wallpaper.directory
      buttonIcon: "folder-open"
      buttonTooltip: I18n.tr("settings.wallpaper.settings.folder.tooltip")
      Layout.fillWidth: true
      onInputEditingFinished: Settings.data.wallpaper.directory = text
      onButtonClicked: mainFolderPicker.open()
    }

    RowLayout {
      NLabel {
        label: I18n.tr("settings.wallpaper.settings.selector.label")
        description: I18n.tr("settings.wallpaper.settings.selector.description")
        Layout.alignment: Qt.AlignTop
      }

      NIconButton {
        icon: "wallpaper-selector"
        tooltipText: I18n.tr("settings.wallpaper.settings.selector.tooltip")
        onClicked: PanelService.getPanel("wallpaperPanel", screen)?.toggle()
      }
    }

    // Recursive search
    NToggle {
      label: I18n.tr("settings.wallpaper.settings.recursive-search.label")
      description: I18n.tr("settings.wallpaper.settings.recursive-search.description")
      checked: Settings.data.wallpaper.recursiveSearch
      onToggled: checked => Settings.data.wallpaper.recursiveSearch = checked
    }

    // Monitor-specific directories
    NToggle {
      label: I18n.tr("settings.wallpaper.settings.monitor-specific.label")
      description: I18n.tr("settings.wallpaper.settings.monitor-specific.description")
      checked: Settings.data.wallpaper.enableMultiMonitorDirectories
      onToggled: checked => Settings.data.wallpaper.enableMultiMonitorDirectories = checked
    }
    // Hide wallpaper filenames
    NToggle {
      label: I18n.tr("settings.wallpaper.settings.hide-wallpaper-filenames.label")
      description: I18n.tr("settings.wallpaper.settings.hide-wallpaper-filenames.description")
      checked: Settings.data.wallpaper.hideWallpaperFilenames
      onToggled: checked => Settings.data.wallpaper.hideWallpaperFilenames = checked
    }

    NBox {
      visible: Settings.data.wallpaper.enableMultiMonitorDirectories

      Layout.fillWidth: true
      radius: Style.radiusM
      color: Color.mSurface
      border.color: Color.mOutline
      border.width: Style.borderS
      implicitHeight: contentCol.implicitHeight + Style.marginL * 2
      clip: true

      ColumnLayout {
        id: contentCol
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginM
        Repeater {
          model: Quickshell.screens || []
          delegate: ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NText {
              text: (modelData.name || "Unknown")
              color: Color.mPrimary
              font.weight: Style.fontWeightBold
              pointSize: Style.fontSizeM
            }

            NTextInputButton {
              text: WallpaperService.getMonitorDirectory(modelData.name)
              buttonIcon: "folder-open"
              buttonTooltip: I18n.tr("settings.wallpaper.settings.monitor-specific.tooltip")
              Layout.fillWidth: true
              onInputEditingFinished: WallpaperService.setMonitorDirectory(modelData.name, text)
              onButtonClicked: {
                specificFolderMonitorName = modelData.name;
                monitorFolderPicker.open();
              }
            }
          }
        }
      }
    }

    NComboBox {
      label: I18n.tr("settings.wallpaper.settings.selector-position.label")
      description: I18n.tr("settings.wallpaper.settings.selector-position.description")
      Layout.fillWidth: true
      model: [
        {
          "key": "follow_bar",
          "name": I18n.tr("options.launcher.position.follow_bar")
        },
        {
          "key": "center",
          "name": I18n.tr("options.launcher.position.center")
        },
        {
          "key": "top_center",
          "name": I18n.tr("options.launcher.position.top_center")
        },
        {
          "key": "top_left",
          "name": I18n.tr("options.launcher.position.top_left")
        },
        {
          "key": "top_right",
          "name": I18n.tr("options.launcher.position.top_right")
        },
        {
          "key": "bottom_left",
          "name": I18n.tr("options.launcher.position.bottom_left")
        },
        {
          "key": "bottom_right",
          "name": I18n.tr("options.launcher.position.bottom_right")
        },
        {
          "key": "bottom_center",
          "name": I18n.tr("options.launcher.position.bottom_center")
        }
      ]
      currentKey: Settings.data.wallpaper.panelPosition
      onSelected: function (key) {
        Settings.data.wallpaper.panelPosition = key;
      }
    }
  }

  ColumnLayout {
    visible: Settings.data.wallpaper.enabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NHeader {
      label: I18n.tr("settings.wallpaper.video.section.label")
      description: I18n.tr("settings.wallpaper.video.section.description")
    }

    NToggle {
      label: I18n.tr("settings.wallpaper.video.playback-enabled.label")
      description: I18n.tr("settings.wallpaper.video.playback-enabled.description")
      checked: Settings.data.wallpaper.videoPlaybackEnabled
      onToggled: checked => Settings.data.wallpaper.videoPlaybackEnabled = checked
    }

    NToggle {
      visible: Settings.data.wallpaper.videoPlaybackEnabled
      label: I18n.tr("settings.wallpaper.video.pause-on-windows.label")
      description: I18n.tr("settings.wallpaper.video.pause-on-windows.description")
      checked: Settings.data.wallpaper.pauseVideoOnWindows
      onToggled: checked => Settings.data.wallpaper.pauseVideoOnWindows = checked
    }

    NToggle {
      visible: Settings.data.wallpaper.videoPlaybackEnabled && Settings.data.wallpaper.pauseVideoOnWindows
      label: I18n.tr("settings.wallpaper.video.pause-on-windows-mute.label")
      description: I18n.tr("settings.wallpaper.video.pause-on-windows-mute.description")
      checked: Settings.data.wallpaper.muteInsteadOfPauseOnWindows
      onToggled: checked => Settings.data.wallpaper.muteInsteadOfPauseOnWindows = checked
    }

    ColumnLayout {
      visible: Settings.data.wallpaper.videoPlaybackEnabled && Settings.data.wallpaper.pauseVideoOnWindows
      spacing: Style.marginS

      ColumnLayout {
        visible: Settings.data.wallpaper.muteInsteadOfPauseOnWindows
        spacing: Style.marginS

        NTextInputButton {
          id: pauseWhitelistInput
          label: I18n.tr("settings.wallpaper.video.pause-on-windows-whitelist.label")
          description: I18n.tr("settings.wallpaper.video.pause-on-windows-whitelist.description")
          placeholderText: I18n.tr("settings.wallpaper.video.pause-on-windows-whitelist.placeholder")
          buttonIcon: "add"
          Layout.fillWidth: true
          onButtonClicked: {
            const val = (pauseWhitelistInput.text || "").trim();
            if (val !== "") {
              const arr = (Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist || []);
              if (!arr.find(x => String(x).toLowerCase() === val.toLowerCase())) {
                Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist = [...arr, val];
                pauseWhitelistInput.text = "";
              }
            }
          }
        }

        Flow {
          Layout.fillWidth: true
          Layout.leftMargin: Style.marginS
          spacing: Style.marginS

          Repeater {
            model: Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist
            delegate: Rectangle {
              required property string modelData
              property real pad: Style.marginS
              color: Qt.alpha(Color.mOnSurface, 0.125)
              border.color: Qt.alpha(Color.mOnSurface, Style.opacityLight)
              border.width: Style.borderS

              RowLayout {
                id: pauseWhitelistChipRow
                spacing: Style.marginXS
                anchors.fill: parent
                anchors.margins: pad

                NText {
                  text: modelData
                  color: Color.mOnSurface
                  pointSize: Style.fontSizeS
                  Layout.alignment: Qt.AlignVCenter
                  Layout.leftMargin: Style.marginS
                }

                NIconButton {
                  icon: "close"
                  baseSize: Style.baseWidgetSize * 0.8
                  Layout.alignment: Qt.AlignVCenter
                  Layout.rightMargin: Style.marginXS
                  onClicked: {
                    const arr = (Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist || []);
                    const idx = arr.findIndex(x => String(x) === modelData);
                    if (idx >= 0) {
                      arr.splice(idx, 1);
                      Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist = arr;
                    }
                  }
                }
              }

              implicitWidth: pauseWhitelistChipRow.implicitWidth + pad * 2
              implicitHeight: Math.max(pauseWhitelistChipRow.implicitHeight + pad * 2, Style.baseWidgetSize * 0.8)
              radius: Style.radiusM
            }
          }
        }
      }

      NTextInputButton {
        id: pauseBlacklistInput
        label: I18n.tr("settings.wallpaper.video.pause-on-windows-blacklist.label")
        description: I18n.tr("settings.wallpaper.video.pause-on-windows-blacklist.description")
        placeholderText: I18n.tr("settings.wallpaper.video.pause-on-windows-blacklist.placeholder")
        buttonIcon: "add"
        Layout.fillWidth: true
        onButtonClicked: {
          const val = (pauseBlacklistInput.text || "").trim();
          if (val !== "") {
            const arr = (Settings.data.wallpaper.pauseVideoOnWindowsBlacklist || []);
            if (!arr.find(x => String(x).toLowerCase() === val.toLowerCase())) {
              Settings.data.wallpaper.pauseVideoOnWindowsBlacklist = [...arr, val];
              pauseBlacklistInput.text = "";
            }
          }
        }
      }

      Flow {
        Layout.fillWidth: true
        Layout.leftMargin: Style.marginS
        spacing: Style.marginS

        Repeater {
          model: Settings.data.wallpaper.pauseVideoOnWindowsBlacklist
          delegate: Rectangle {
            required property string modelData
            property real pad: Style.marginS
            color: Qt.alpha(Color.mOnSurface, 0.125)
            border.color: Qt.alpha(Color.mOnSurface, Style.opacityLight)
            border.width: Style.borderS

            RowLayout {
              id: pauseChipRow
              spacing: Style.marginXS
              anchors.fill: parent
              anchors.margins: pad

              NText {
                text: modelData
                color: Color.mOnSurface
                pointSize: Style.fontSizeS
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: Style.marginS
              }

              NIconButton {
                icon: "close"
                baseSize: Style.baseWidgetSize * 0.8
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: Style.marginXS
                onClicked: {
                  const arr = (Settings.data.wallpaper.pauseVideoOnWindowsBlacklist || []);
                  const idx = arr.findIndex(x => String(x) === modelData);
                  if (idx >= 0) {
                    arr.splice(idx, 1);
                    Settings.data.wallpaper.pauseVideoOnWindowsBlacklist = arr;
                  }
                }
              }
            }

            implicitWidth: pauseChipRow.implicitWidth + pad * 2
            implicitHeight: Math.max(pauseChipRow.implicitHeight + pad * 2, Style.baseWidgetSize * 0.8)
            radius: Style.radiusM
          }
        }
      }
    }

    NToggle {
      visible: Settings.data.wallpaper.videoPlaybackEnabled
      enabled: steamIntegrationAvailable
      opacity: steamIntegrationAvailable ? 1.0 : 0.35
      checked: Settings.data.wallpaper.steamWallpaperIntegration
      label: I18n.tr("settings.wallpaper.video.steam-integration.label")
      description: I18n.tr("settings.wallpaper.video.steam-integration.description")
      onToggled: checked => {
        if (steamIntegrationAvailable) {
          Settings.data.wallpaper.steamWallpaperIntegration = checked;
        }
      }
    }
    NText {
      visible: Settings.data.wallpaper.videoPlaybackEnabled && !steamIntegrationAvailable
      text: I18n.tr("settings.wallpaper.video.steam-integration-unavailable")
      color: Color.mError
      pointSize: Style.fontSizeS
    }

    NToggle {
      label: I18n.tr("settings.wallpaper.video.audio-muted.label")
      description: I18n.tr("settings.wallpaper.video.audio-muted.description")
      checked: Settings.data.wallpaper.videoAudioMuted
      onToggled: checked => Settings.data.wallpaper.videoAudioMuted = checked
      visible: Settings.data.wallpaper.videoPlaybackEnabled
    }

    ColumnLayout {
      visible: Settings.data.wallpaper.videoPlaybackEnabled

      NLabel {
        label: I18n.tr("settings.wallpaper.video.audio-volume.label")
        description: I18n.tr("settings.wallpaper.video.audio-volume.description")
      }

      NValueSlider {
        Layout.fillWidth: true
        from: 0.0
        to: 1.0
        stepSize: 0.01
        value: Settings.data.wallpaper.videoAudioVolume
        onMoved: value => Settings.data.wallpaper.videoAudioVolume = value
        text: Math.round(Settings.data.wallpaper.videoAudioVolume * 100) + "%"
      }
    }

    // Lock Screen Video Settings
    NHeader {
      label: I18n.tr("settings.wallpaper.video.lockscreen.section.label")
      description: I18n.tr("settings.wallpaper.video.lockscreen.section.description")
    }

    NComboBox {
      label: I18n.tr("settings.wallpaper.video.lockscreen.mode.label")
      description: I18n.tr("settings.wallpaper.video.lockscreen.mode.description")
      model: [
        {
          "key": "normal",
          "name": I18n.tr("settings.wallpaper.video.lockscreen.mode.normal")
        },
        {
          "key": "muted",
          "name": I18n.tr("settings.wallpaper.video.lockscreen.mode.muted")
        },
        {
          "key": "disabled",
          "name": I18n.tr("settings.wallpaper.video.lockscreen.mode.disabled")
        }
      ]
      currentKey: Settings.data.wallpaper.lockscreenVideoMode
      onSelected: key => Settings.data.wallpaper.lockscreenVideoMode = key
    }
  }

  NDivider {
    visible: Settings.data.wallpaper.enabled
    Layout.fillWidth: true
    Layout.topMargin: Style.marginL
    Layout.bottomMargin: Style.marginL
  }

  ColumnLayout {
    visible: Settings.data.wallpaper.enabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NHeader {
      label: I18n.tr("settings.wallpaper.look-feel.section.label")
    }

    // Fill Mode
    NComboBox {
      label: I18n.tr("settings.wallpaper.look-feel.fill-mode.label")
      description: I18n.tr("settings.wallpaper.look-feel.fill-mode.description")
      model: WallpaperService.fillModeModel
      currentKey: Settings.data.wallpaper.fillMode
      onSelected: key => Settings.data.wallpaper.fillMode = key
    }

    RowLayout {
      NLabel {
        label: I18n.tr("settings.wallpaper.look-feel.fill-color.label")
        description: I18n.tr("settings.wallpaper.look-feel.fill-color.description")
        Layout.alignment: Qt.AlignTop
      }

      NColorPicker {
        selectedColor: Settings.data.wallpaper.fillColor
        onColorSelected: color => Settings.data.wallpaper.fillColor = color
      }
    }

    // Transition Type
    NComboBox {
      label: I18n.tr("settings.wallpaper.look-feel.transition-type.label")
      description: I18n.tr("settings.wallpaper.look-feel.transition-type.description")
      model: WallpaperService.transitionsModel
      currentKey: Settings.data.wallpaper.transitionType
      onSelected: key => Settings.data.wallpaper.transitionType = key
    }

    // Transition Duration
    ColumnLayout {
      NLabel {
        label: I18n.tr("settings.wallpaper.look-feel.transition-duration.label")
        description: I18n.tr("settings.wallpaper.look-feel.transition-duration.description")
      }

      NValueSlider {
        Layout.fillWidth: true
        from: 500
        to: 10000
        stepSize: 100
        value: Settings.data.wallpaper.transitionDuration
        onMoved: value => Settings.data.wallpaper.transitionDuration = value
        text: (Settings.data.wallpaper.transitionDuration / 1000).toFixed(1) + "s"
      }
    }

    // Edge Smoothness
    ColumnLayout {
      NLabel {
        label: I18n.tr("settings.wallpaper.look-feel.edge-smoothness.label")
        description: I18n.tr("settings.wallpaper.look-feel.edge-smoothness.description")
      }

      NValueSlider {
        Layout.fillWidth: true
        from: 0.0
        to: 1.0
        value: Settings.data.wallpaper.transitionEdgeSmoothness
        onMoved: value => Settings.data.wallpaper.transitionEdgeSmoothness = value
        text: Math.round(Settings.data.wallpaper.transitionEdgeSmoothness * 100) + "%"
      }
    }
  }

  NDivider {
    visible: Settings.data.wallpaper.enabled
    Layout.fillWidth: true
    Layout.topMargin: Style.marginL
    Layout.bottomMargin: Style.marginL
  }

  ColumnLayout {
    visible: Settings.data.wallpaper.enabled
    spacing: Style.marginL
    Layout.fillWidth: true

    NHeader {
      label: I18n.tr("settings.wallpaper.automation.section.label")
    }

    // Random Wallpaper
    NToggle {
      label: I18n.tr("settings.wallpaper.automation.random-wallpaper.label")
      description: I18n.tr("settings.wallpaper.automation.random-wallpaper.description")
      checked: Settings.data.wallpaper.randomEnabled
      onToggled: checked => Settings.data.wallpaper.randomEnabled = checked
    }

    // Interval
    ColumnLayout {
      visible: Settings.data.wallpaper.randomEnabled
      RowLayout {
        NLabel {
          label: I18n.tr("settings.wallpaper.automation.interval.label")
          description: I18n.tr("settings.wallpaper.automation.interval.description")
          Layout.fillWidth: true
        }

        NText {
          // Show friendly H:MM format from current settings
          text: Time.formatVagueHumanReadableDuration(Settings.data.wallpaper.randomIntervalSec)
          Layout.alignment: Qt.AlignBottom | Qt.AlignRight
        }
      }

      // Preset chips using Repeater
      RowLayout {
        id: presetRow
        spacing: Style.marginS

        // Factorized presets data
        property var intervalPresets: [5 * 60, 10 * 60, 15 * 60, 30 * 60, 45 * 60, 60 * 60, 90 * 60, 120 * 60]

        // Whether current interval equals one of the presets
        property bool isCurrentPreset: {
          return intervalPresets.some(seconds => seconds === Settings.data.wallpaper.randomIntervalSec);
        }
        // Allow user to force open the custom input; otherwise it's auto-open when not a preset
        property bool customForcedVisible: false

        function setIntervalSeconds(sec) {
          Settings.data.wallpaper.randomIntervalSec = sec;
          WallpaperService.restartRandomWallpaperTimer();
          // Hide custom when selecting a preset
          customForcedVisible = false;
        }

        // Helper to color selected chip
        function isSelected(sec) {
          return Settings.data.wallpaper.randomIntervalSec === sec;
        }

        // Repeater for preset chips
        Repeater {
          model: presetRow.intervalPresets
          delegate: IntervalPresetChip {
            seconds: modelData
            label: Time.formatVagueHumanReadableDuration(modelData)
            selected: presetRow.isSelected(modelData)
            onClicked: presetRow.setIntervalSeconds(modelData)
          }
        }

        // Custom… opens inline input
        IntervalPresetChip {
          label: customRow.visible ? "Custom" : "Custom…"
          selected: customRow.visible
          onClicked: presetRow.customForcedVisible = !presetRow.customForcedVisible
        }
      }

      // Custom HH:MM inline input
      RowLayout {
        id: customRow
        visible: presetRow.customForcedVisible || !presetRow.isCurrentPreset
        spacing: Style.marginS
        Layout.topMargin: Style.marginS

        NTextInput {
          label: I18n.tr("settings.wallpaper.automation.custom-interval.label")
          description: I18n.tr("settings.wallpaper.automation.custom-interval.description")
          text: {
            const s = Settings.data.wallpaper.randomIntervalSec;
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            return h + ":" + (m < 10 ? ("0" + m) : m);
          }
          onEditingFinished: {
            const m = text.trim().match(/^(\d{1,2}):(\d{2})$/);
            if (m) {
              let h = parseInt(m[1]);
              let min = parseInt(m[2]);
              if (isNaN(h) || isNaN(min))
                return;
              h = Math.max(0, Math.min(24, h));
              min = Math.max(0, Math.min(59, min));
              Settings.data.wallpaper.randomIntervalSec = (h * 3600) + (min * 60);
              WallpaperService.restartRandomWallpaperTimer();
              // Keep custom visible after manual entry
              presetRow.customForcedVisible = true;
            }
          }
        }
      }
    }
  }

  // Reusable component for interval preset chips
  component IntervalPresetChip: Rectangle {
    property int seconds: 0
    property string label: ""
    property bool selected: false
    signal clicked

    radius: height * 0.5
    color: selected ? Color.mPrimary : Color.mSurfaceVariant
    implicitHeight: Math.max(Style.baseWidgetSize * 0.55, 24)
    implicitWidth: chipLabel.implicitWidth + Style.marginM * 1.5
    border.width: Style.borderS
    border.color: selected ? Color.transparent : Color.mOutline

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }

    NText {
      id: chipLabel
      anchors.centerIn: parent
      text: parent.label
      pointSize: Style.fontSizeS
      color: parent.selected ? Color.mOnPrimary : Color.mOnSurface
    }
  }

  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginL
    Layout.bottomMargin: Style.marginL
  }

  NFilePicker {
    id: mainFolderPicker
    selectionMode: "folders"
    title: I18n.tr("settings.wallpaper.settings.select-folder")
    initialPath: Settings.data.wallpaper.directory || Quickshell.env("HOME") + "/Pictures"
    onAccepted: paths => {
                  if (paths.length > 0) {
                    Settings.data.wallpaper.directory = paths[0];
                  }
                }
  }

  NFilePicker {
    id: monitorFolderPicker
    selectionMode: "folders"
    title: I18n.tr("settings.wallpaper.settings.select-monitor-folder")
    initialPath: WallpaperService.getMonitorDirectory(specificFolderMonitorName) || Quickshell.env("HOME") + "/Pictures"
    onAccepted: paths => {
                  if (paths.length > 0) {
                    WallpaperService.setMonitorDirectory(specificFolderMonitorName, paths[0]);
                  }
                }
  }
}
