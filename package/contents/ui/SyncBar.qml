import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Compare legend + filter chips + directional "transfer matching" buttons.
// Shown only while fm.compareMode is on.
ColumnLayout {
    id: sync
    property var fm
    spacing: Kirigami.Units.smallSpacing / 2

    // legend
    Flow {
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing
        Repeater {
            model: [
                { g: "○", c: Kirigami.Theme.positiveTextColor, t: i18n("only one side") },
                { g: "≠", c: Kirigami.Theme.neutralTextColor,  t: i18n("size differs") },
                { g: "▲", c: Kirigami.Theme.neutralTextColor,  t: i18n("newer local") },
                { g: "▼", c: Kirigami.Theme.neutralTextColor,  t: i18n("newer remote") }
            ]
            delegate: RowLayout {
                spacing: 2
                PlasmaComponents.Label { text: modelData.g; color: modelData.c; font: Kirigami.Theme.smallFont }
                PlasmaComponents.Label { text: modelData.t; opacity: 0.7; font: Kirigami.Theme.smallFont }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label { text: i18n("Show:"); opacity: 0.7; font: Kirigami.Theme.smallFont }
        Repeater {
            model: [
                { key: "all",   label: i18n("All differing") },
                { key: "new",   label: i18n("Only new") },
                { key: "size",  label: i18n("Only size-differs") },
                { key: "newer", label: i18n("Newer only") }
            ]
            delegate: QQC2.Button {
                text: modelData.label
                checkable: true
                checked: sync.fm.syncFilter === modelData.key
                onClicked: sync.fm.syncFilter = modelData.key
                font: Kirigami.Theme.smallFont
            }
        }
        Item { Layout.fillWidth: true }
        QQC2.Button {
            text: i18n("Transfer →"); icon.name: "go-next"
            onClicked: sync.fm.transferMatching("up")
            PlasmaComponents.ToolTip { text: i18n("Send matching local files to the remote") }
        }
        QQC2.Button {
            text: i18n("← Transfer"); icon.name: "go-previous"
            onClicked: sync.fm.transferMatching("down")
            PlasmaComponents.ToolTip { text: i18n("Bring matching remote files to local") }
        }
    }
}
