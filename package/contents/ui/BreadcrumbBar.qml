import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// Clickable path segments. Emits navigate(path) when a segment is clicked.
Flickable {
    id: bar
    property string path: "/"
    signal navigate(string path)

    implicitHeight: row.implicitHeight
    contentWidth: row.implicitWidth
    contentHeight: row.implicitHeight
    clip: true
    flickableDirection: Flickable.HorizontalFlick
    // keep the deepest segment in view
    onPathChanged: Qt.callLater(function () { bar.contentX = Math.max(0, row.implicitWidth - bar.width); })

    RowLayout {
        id: row
        spacing: 0
        Repeater {
            model: Fmt.pathCrumbs(bar.path)
            delegate: RowLayout {
                spacing: 0
                PlasmaComponents.Label {
                    visible: index > 0
                    text: "›"
                    opacity: 0.5
                    leftPadding: Kirigami.Units.smallSpacing / 2
                    rightPadding: Kirigami.Units.smallSpacing / 2
                }
                PlasmaComponents.ToolButton {
                    text: modelData.label
                    flat: true
                    font.bold: index === Fmt.pathCrumbs(bar.path).length - 1
                    onClicked: bar.navigate(modelData.path)
                }
            }
        }
    }
}
