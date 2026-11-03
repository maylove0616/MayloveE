# Third-party notices

MayloveE is licensed under the MIT License (see `LICENSE`). Release builds include the following
third-party components, each under its own license.

| Component | License | Source |
|---|---|---|
| Eclipse JDT Language Server (jdtls) | Eclipse Public License 2.0 | https://github.com/eclipse-jdtls/eclipse.jdt.ls |
| OpenJDK runtime (created with jlink) | GNU General Public License v2 with the Classpath Exception | https://openjdk.org |
| SwiftTreeSitter | BSD 3-Clause License | https://github.com/ChimeHQ/SwiftTreeSitter |
| tree-sitter | MIT License | https://github.com/tree-sitter/tree-sitter |
| tree-sitter-java | MIT License | https://github.com/tree-sitter/tree-sitter-java |

In the app bundle, the license texts are in `Contents/Resources/Licenses` (jdtls's notice is
`jdtls-about.html`; the jdtls plugins also carry their own `about.html` files) and the OpenJDK
legal notices are in `Contents/Resources/jre/legal`.

jdtls is distributed unmodified. Its source code is available from the project above and from
https://download.eclipse.org/jdtls/.
