import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// Left strip of a FilePane: standard places + favorite folders for this side.
// Reads ctrl.favPathsFor(side), kept reactive via the ctrl.favPaths binding.
ColumnLayout {
    id: strip
    property var ctrl
    property var pane
    property string side: "local"
    property string homePath: ""
    spacing: Kirigami.Units.smallSpacing / 2

    // standard, non-removable places
    readonly property var standardPlaces: side === "local"
        ? [ { label: i18n("Home"), path: homePath || "~", icon: "user-home" },
            { label: "/",          path: "/",              icon: "folder-root" } ]
        : [ { label: "/",          path: "/",              icon: "folder-root" },
            { label: i18n("Home"), path: homePath || "/root", icon: "user-home" } ]

    PlasmaComponents.Label {
        text: i18n("Places"); opacity: 0.6; font: Kirigami.Theme.smallFont
        Layout.fillWidth: true
    }
    Repeater {
        model: strip.standardPlaces
        delegate: PlaceItem {
            label: modelData.label
            iconName: modelData.icon
            onActivated: strip.pane.cd(modelData.path)
        }
    }

    Kirigami.Separator { Layout.fillWidth: true; visible: favRepeater.count > 0 }
    PlasmaComponents.Label {
        text: i18n("Favorites"); opacity: 0.6; font: Kirigami.Theme.smallFont
        Layout.fillWidth: true; visible: favRepeater.count > 0
    }
    Repeater {
        id: favRepeater
        model: strip.ctrl ? strip.ctrl.favPathsFor(strip.side) : []
        delegate: PlaceItem {
            label: Fmt.baseName(modelData) || modelData
            iconName: "folder"
            removable: true
            tip: modelData
            onActivated: strip.pane.cd(modelData)
            onRemove: strip.ctrl.toggleFavPath(strip.side, modelData)
        }
    }

    Item { Layout.fillHeight: true }

    component PlaceItem: PlasmaComponents.ItemDelegate {
        id: pi
        property string label: ""
        property string iconName: "folder"
        property bool removable: false
        property string tip: ""
        signal activated()
        signal remove()
        Layout.fillWidth: true
        hoverEnabled: true
        onClicked: pi.activated()
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: pi.iconName
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PlasmaComponents.Label { text: pi.label; Layout.fillWidth: true; elide: Text.ElideMiddle }
            PlasmaComponents.ToolButton {
                visible: pi.removable && pi.hovered
                icon.name: "list-remove"
                icon.width: Kirigami.Units.iconSizes.small
                flat: true
                onClicked: pi.remove()
            }
        }
        PlasmaComponents.ToolTip { text: pi.tip; visible: pi.tip !== "" && pi.hovered }
    }
}
