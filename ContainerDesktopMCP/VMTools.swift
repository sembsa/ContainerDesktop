import Foundation

/// QEMU VM tools (`vm_screenshot`, `vm_click`, `vm_type`, `vm_key`, `vm_exec`,
/// `vm_copy_in`/`vm_copy_out`, `vm_snapshot`) go here, built on the QMP/QGA
/// clients and `ContainerGUI/Common/RFB/`. A screenshot returns
/// `MCPToolResult(content: [.image(pngData, mimeType: "image/png")])`.
/// Add the engine's source files to the `ContainerDesktopMCP` target in project.yml.
enum VMTools {
    static let all: [MCPTool] = []
}
