import AppKit

// Modo de linha de comando para testar os conversores sem interface:
//   Toranja --cli convert <ext> <arquivo>…
//   Toranja --cli <ferramenta> <arquivo>…
let args = CommandLine.arguments
if args.count > 2 && args[1] == "--cli" {
    exit(MainActor.assumeIsolated { CLI.run(Array(args.dropFirst(2))) })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
