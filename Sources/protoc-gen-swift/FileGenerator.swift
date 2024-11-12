// Sources/protoc-gen-swift/FileGenerator.swift - File-level generation logic
//
// Copyright (c) 2014 - 2016 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// This provides the logic for each file that is stored in the plugin request.
/// In particular, generateOutputFile() actually builds a Swift source file
/// to represent a single .proto input.  Note that requests typically contain
/// a number of proto files that are not to be generated.
///
// -----------------------------------------------------------------------------
import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

class FileGenerator {
    private let fileDescriptor: FileDescriptor
    private let generatorOptions: GeneratorOptions
    private let namer: SwiftProtobufNamer
    private let shortenTypeNaming: Bool

    var outputFilename: String {
        let ext = ".pb.swift"
        let pathParts = splitPath(pathname: fileDescriptor.name)
        switch generatorOptions.outputNaming {
        case .fullPath:
            return pathParts.dir + pathParts.base + ext
        case .pathToUnderscores:
            let dirWithUnderscores =
                pathParts.dir.replacingOccurrences(of: "/", with: "_")
            return dirWithUnderscores + pathParts.base + ext
        case .dropPath:
            return pathParts.base + ext
        }
    }

    init(
        fileDescriptor: FileDescriptor,
        generatorOptions: GeneratorOptions
    ) {
        self.fileDescriptor = fileDescriptor
        self.generatorOptions = generatorOptions
        namer = SwiftProtobufNamer(
            currentFile: fileDescriptor,
            protoFileToModuleMappings: generatorOptions.protoToModuleMappings
        )

        self.shortenTypeNaming = generatorOptions.shortenTypeNamingFiles.contains { fileDescriptor.name.contains($0) }
    }

    /// Generate, if `errorString` gets filled in, then report error instead of using
    /// what written into `printer`.
    func generateOutputFile(printer p: inout CodePrinter, errorString: inout String?) {
        guard
            fileDescriptor.options.swiftPrefix.isEmpty
                || isValidSwiftIdentifier(
                    fileDescriptor.options.swiftPrefix,
                    allowQuoted: false
                )
        else {
            errorString =
                "\(fileDescriptor.name) has an 'swift_prefix' that isn't a valid Swift identifier (\(fileDescriptor.options.swiftPrefix))."
            return
        }
        p.print(
            """
            // DO NOT EDIT.
            // swift-format-ignore-file
            // swiftlint:disable all
            //
            // Generated by the Swift generator plugin for the protocol buffer compiler.
            // Source: \(fileDescriptor.name)
            // Generation mode: \(generatorOptions.generationMode)
            //
            // For information on using the generated types, please see the documentation:
            //   https://github.com/apple/swift-protobuf/

            """
        )

        // Attempt to bring over the comments at the top of the .proto file as
        // they likely contain copyrights/preamble/etc.
        //
        // The C++ FileDescriptor::GetSourceLocation(), says the location for
        // the file is an empty path. That never seems to have comments on it.
        // https://github.com/protocolbuffers/protobuf/issues/2249 opened to
        // figure out the right way to do this but going forward best bet seems
        // to be to look for the "edition" or the "syntax" decl.
        let editionPath = IndexPath(index: Google_Protobuf_FileDescriptorProto.FieldNumbers.edition)
        let syntaxPath = IndexPath(index: Google_Protobuf_FileDescriptorProto.FieldNumbers.syntax)
        var commentLocation: Google_Protobuf_SourceCodeInfo.Location? = nil
        if let location = fileDescriptor.sourceCodeInfoLocation(path: editionPath) {
            commentLocation = location
        } else if let location = fileDescriptor.sourceCodeInfoLocation(path: syntaxPath) {
            commentLocation = location
        }
        if let commentLocation = commentLocation {
            let comments = commentLocation.asSourceComment(
                commentPrefix: "///",
                leadingDetachedPrefix: "//"
            )
            if !comments.isEmpty {
                // If the was a leading or tailing comment it won't have a blank
                // line, after it, so ensure there is one.
                p.print(comments, newlines: !comments.hasSuffix("\n\n"))
            }
        }

        guard !generatorOptions.isLiteMode else {
            generateOutputFileLite(printer: &p, errorString: &errorString)
            return
        }

        let fileDefinesTypes =
            !fileDescriptor.enums.isEmpty || !fileDescriptor.messages.isEmpty || !fileDescriptor.extensions.isEmpty

        var hasImports = false
        if fileDescriptor.needsFoundationImport {
            p.print("\(generatorOptions.importDirective.snippet) Foundation")
            hasImports = true
        }

        if fileDescriptor.isBundledProto {
            p.print(
                "// 'import \(namer.swiftProtobufModuleName)' suppressed, this proto file is meant to be bundled in the runtime."
            )
            hasImports = true
        } else if fileDefinesTypes {
            p.print("\(generatorOptions.importDirective.snippet) \(namer.swiftProtobufModuleName)")
            hasImports = true
        }

        let neededImports = fileDescriptor.computeImports(
            namer: namer,
            directive: generatorOptions.importDirective,
            reexportPublicImports: generatorOptions.visibility != .internal
        )
        if !neededImports.isEmpty {
            if hasImports {
                p.print()
            }
            p.print(neededImports)
            hasImports = true
        }

        // If there is nothing to generate, then just record that and be done (usually means
        // there just was one or more services).
        guard fileDefinesTypes else {
            if hasImports {
                p.print()
            }
            p.print("// This file contained no messages, enums, or extensions.")
            return
        }

        p.print()
        generateVersionCheck(printer: &p)

        let extensionSet =
            ExtensionSetGenerator(
                fileDescriptor: fileDescriptor,
                generatorOptions: generatorOptions,
                namer: namer
            )

        extensionSet.add(extensionFields: fileDescriptor.extensions)

        let enums = fileDescriptor.enums.map {
            EnumGenerator(descriptor: $0, generatorOptions: generatorOptions, namer: namer)
        }

        let messages = fileDescriptor.messages.map {
            MessageGenerator(
                descriptor: $0,
                generatorOptions: generatorOptions,
                namer: namer,
                extensionSet: extensionSet
            )
        }

        for e in enums {
            e.generateMainEnum(printer: &p)
        }

        for m in messages {
            m.generateMainStruct(printer: &p, parent: nil, errorString: &errorString)
        }

        if !extensionSet.isEmpty {
            let pathParts = splitPath(pathname: fileDescriptor.name)
            let filename = pathParts.base + pathParts.suffix
            p.print(
                "",
                "// MARK: - Extension support defined in \(filename)."
            )

            // Generate the Swift Extensions on the Messages that provide the api
            // for using the protobuf extension.
            extensionSet.generateMessageSwiftExtensions(printer: &p)

            // Generate a registry for the file.
            extensionSet.generateFileProtobufExtensionRegistry(printer: &p)

            // Generate the Extension's declarations (used by the two above things).
            //
            // This is done after the other two as the only time developers will need
            // these symbols is if they are manually building their own ExtensionMap;
            // so the others are assumed more interesting.
            extensionSet.generateProtobufExtensionDeclarations(printer: &p)
        }

        let protoPackage = fileDescriptor.package
        let needsProtoPackage: Bool = !protoPackage.isEmpty && !messages.isEmpty
        if needsProtoPackage || !enums.isEmpty || !messages.isEmpty {
            p.print(
                "",
                "// MARK: - Code below here is support for the SwiftProtobuf runtime."
            )
            if needsProtoPackage {
                p.print(
                    "",
                    "fileprivate let _protobuf_package = \"\(protoPackage)\""
                )
            }
            for e in enums {
                e.generateRuntimeSupport(printer: &p)
            }
            for m in messages {
                m.generateRuntimeSupport(printer: &p, file: self, parent: nil)
            }
        }
    }

    private func generateVersionCheck(printer p: inout CodePrinter) {
        let v = Version.compatibilityVersion
        p.print(
            """
            // If the compiler emits an error on this type, it is because this file
            // was generated by a version of the `protoc` Swift plug-in that is
            // incompatible with the version of SwiftProtobuf to which you are linking.
            // Please ensure that you are building against the same version of the API
            // that was used to generate this file.
            fileprivate struct _GeneratedWithProtocGenSwiftVersion: \(namer.swiftProtobufModulePrefix)ProtobufAPIVersionCheck {
            """
        )
        p.printIndented(
            "struct _\(v): \(namer.swiftProtobufModulePrefix)ProtobufAPIVersion_\(v) {}",
            "typealias Version = _\(v)"
        )
        p.print("}")
    }
}

// MARK: - Lite
private extension FileGenerator {
    /// `GenerationMode: lite`
    /// Generate, if `errorString` gets filled in, then report error instead of using
    /// what written into `printer`.
    func generateOutputFileLite(printer p: inout CodePrinter, errorString: inout String?) {
        let fileDefinesTypes =
            !fileDescriptor.enums.isEmpty || !fileDescriptor.messages.isEmpty || !fileDescriptor.extensions.isEmpty

        // If there is nothing to generate, then just record that and be done (usually means
        // there just was one or more services).
        guard fileDefinesTypes else {
            p.print()
            p.print("// This file contained no messages, enums, or extensions.")
            return
        }

        p.print("import Foundation")

        let extensionSet =
            ExtensionSetGenerator(
                fileDescriptor: fileDescriptor,
                generatorOptions: generatorOptions,
                namer: namer
            )

        extensionSet.add(extensionFields: fileDescriptor.extensions)

        let enums = fileDescriptor.enums.map {
            EnumGenerator(descriptor: $0, generatorOptions: generatorOptions, namer: namer, shortenNaming: shortenTypeNaming)
        }

        let messages = fileDescriptor.messages.map {
            MessageGenerator(
                descriptor: $0,
                generatorOptions: generatorOptions,
                namer: namer,
                extensionSet: extensionSet,
                shortenNaming: shortenTypeNaming
            )
        }

        for e in enums {
            e.generateMainEnum(printer: &p)
        }

        for m in messages {
            m.generateMainStruct(printer: &p, parent: nil, errorString: &errorString)
        }
    }
}
