import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Panel/compact view: the custom icon with a running/total badge and a
// reachability dot. Click toggles the popup.
MouseArea {
    id: ca

    property bool reachable: false
    property bool dockerOk: false
    property int runningCount: 0
    property int totalCount: 0
    property url iconSource

    signal toggleRequested()

    readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
    readonly property int side: Math.min(width, height)

    hoverEnabled: true
    onClicked: ca.toggleRequested()

    Layout.minimumWidth: horizontal ? (row.implicitWidth) : Kirigami.Units.iconSizes.small
    Layout.preferredWidth: horizontal ? row.implicitWidth : height

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        Item {
            Layout.fillHeight: true
            Layout.preferredWidth: height
            Layout.alignment: Qt.AlignCenter

            Image {
                id: icon
                anchors.fill: parent
                source: ca.iconSource
                sourceSize.width: 128
                sourceSize.height: 128
                fillMode: Image.PreserveAspectFit
                smooth: true
                opacity: ca.reachable ? 1.0 : 0.55
            }

            // reachability dot, bottom-right
            Rectangle {
                width: Math.max(6, parent.width * 0.26)
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                color: !ca.reachable ? Kirigami.Theme.negativeTextColor
                     : !ca.dockerOk  ? Kirigami.Theme.neutralTextColor
                     :                 Kirigami.Theme.positiveTextColor
                border.width: Math.max(1, width * 0.12)
                border.color: Kirigami.Theme.backgroundColor
            }
        }

        PlasmaComponents.Label {
            visible: ca.horizontal && ca.dockerOk && ca.width > Kirigami.Units.gridUnit * 3.5
            text: ca.runningCount + "/" + ca.totalCount
            font.bold: true
            font.family: "monospace"
            color: ca.runningCount > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
