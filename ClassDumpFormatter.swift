#!/usr/bin/env xcrun swift

import Foundation

// MARK: Helpers

extension String {
  /// Splits a string into substrings, delineated by newline characters.
  func componentsSeparatedByNewlines() -> [String] {
    return (self as NSString).componentsSeparatedByCharactersInSet(NSCharacterSet.newlineCharacterSet())
  }
}

extension NSMutableString {
  /// Returns a range that encompasses the entire string.
  var rangeOfEntireString: NSRange {
    return NSRange(location: 0, length: length)
  }

  /// Removes occurrences of "(" and ")".
  func removeParentheses() {
    let options = NSStringCompareOptions.CaseInsensitiveSearch
    replaceOccurrencesOfString("(", withString: "", options: options, range: rangeOfEntireString)
    replaceOccurrencesOfString(")", withString: "", options: options, range: rangeOfEntireString)
  }

  /// Replaces all whitespace " " with the given string.
  func replaceOccurencesOfWhitespaceWithString(string: String) {
    replaceOccurrencesOfString(" ", withString: string, options: NSStringCompareOptions.CaseInsensitiveSearch, range: rangeOfEntireString)
  }
}

extension NSString {
  /// Returns a boolean indicating whether a line begins with "@protocol" or "@interface".
  /// We naively assume that this means the line contains the beginning of a protocol
  /// or class declaration.
  var hasDeclarationPrefix: Bool {
    return hasPrefix("@protocol") || hasPrefix("@interface")
  }

  /// Splits a string into substrings, delineated by whitespace.
  var componentsSeparatedByWhitespace: [NSString] {
    return componentsSeparatedByCharactersInSet(NSCharacterSet.whitespaceCharacterSet())
  }

  var indexOfFirstOccurrenceOfColonCharacter: Array<NSString>.Index? {
    return componentsSeparatedByWhitespace.indexOf { $0.isEqualToString(":") }
  }

  var isProtocolDeclaration: Bool {
    return indexOfFirstOccurrenceOfColonCharacter == nil
  }

  var declarationName: String {
    let components = componentsSeparatedByWhitespace
    let componentsAfterKeyword = Array(components[1..<components.count])
    let stringAfterKeyword = (componentsAfterKeyword as NSArray).componentsJoinedByString(" ")
    if isProtocolDeclaration {
      let stringAfterKeywordAndBeforeAngleBracket = stringAfterKeyword.componentsSeparatedByString(" <")[0]
      let name = NSMutableString(string: stringAfterKeywordAndBeforeAngleBracket)
      name.removeParentheses()
      name.replaceOccurencesOfWhitespaceWithString("+")
      return name as String
    } else {
      let colonIndex = Int(stringAfterKeyword.indexOfFirstOccurrenceOfColonCharacter!.value)
      return (Array(componentsAfterKeyword[0..<colonIndex]) as NSArray).componentsJoinedByString(" ")
    }
  }

  /// Returns a boolean indicating whether a line ends with "@end".
  /// We naively assume that this means the line ends a protocol or class declaration.
  var hasEndPrefix: Bool {
    return hasPrefix("@end")
  }
}

extension Array where Element : NSString {
  /// Joins an array of NSString elements into a single string
  /// using the specified newline separator.
  func joinWithNewlines(newlineCharacter: String = "\n") -> String {
    return (self as NSArray).componentsJoinedByString(newlineCharacter)
  }

  func mapDeclarations<TransformedValue>(closure: (linesInDeclaration: [NSString]) -> (TransformedValue)) {
    var inDeclaration = false
    var linesInDeclaration: [NSString] = []
    for line in self {
      if line.hasDeclarationPrefix {
        inDeclaration = true
      }

      if inDeclaration {
        linesInDeclaration.append(line)
      }

      if line.hasEndPrefix {
        closure(linesInDeclaration: linesInDeclaration)
        inDeclaration = false
        linesInDeclaration.removeAll()
      }
    }
  }

  /// A header comment prepended to each file generated with this script.
  /// It includes copyright for class-dump, among other things.
  var classDumpHeader: String {
    let commentLines = filter { $0.hasPrefix("//") }
    let headerCommentLines = commentLines.filter { !$0.hasSuffix("properties") }
    return headerCommentLines.joinWithNewlines()
  }
}

/// Errors emitted when running ClassDumpFormatter.
enum ClassDumpFormatterError: ErrorType {
  /// class-dump was unable to provide any data we could convert into a string.
  case InvalidData
  /// Could not create a file at the given URL.
  case InvalidFileURL(url: NSURL)
}

/// Runs class-dump on a Mach-O file.
func classDump(executablePath: String, machOFilePath: String) throws -> String {
  let pipe = NSPipe()
  let fileHandle = pipe.fileHandleForReading
  let task = NSTask()
  task.launchPath = executablePath
  task.arguments = [machOFilePath]
  task.standardOutput = pipe

  task.launch()

  let data = fileHandle.readDataToEndOfFile()
  fileHandle.closeFile()

  if let output = NSString(data: data, encoding: NSUTF8StringEncoding) {
    return output as String
  } else {
    throw ClassDumpFormatterError.InvalidData
  }
}

struct ClassDumpDeclaration {
  let name: String
  let header: String
  let declaration: String

  var fileName: String {
    return "\(name).h"
  }

  var fileBody: String {
    return "\(declaration)\n"
  }
}

extension NSFileManager {
  func createFileForHeader(header: String, inDirectoryAtPath: String) throws {
    let url = NSURL(fileURLWithPath: inDirectoryAtPath).URLByAppendingPathComponent("class-dump-version.h")
    guard let path = url.path else {
      throw ClassDumpFormatterError.InvalidFileURL(url: url)
    }
    try header.writeToFile(path, atomically: true, encoding: NSUTF8StringEncoding)
  }

  func createFileForDeclaration(declaration: ClassDumpDeclaration, inDirectoryAtPath: String) throws {
    let url = NSURL(fileURLWithPath: inDirectoryAtPath).URLByAppendingPathComponent(declaration.fileName)
    guard let path = url.path else {
      throw ClassDumpFormatterError.InvalidFileURL(url: url)
    }
    try declaration.fileBody.writeToFile(path, atomically: true, encoding: NSUTF8StringEncoding)
  }
}

/// A parsed set of arguments for this script.
struct ClassDumpFormatterArguments {
  /// The path to a class-dump executable.
  let classDumpExecutablePath: String
  /// The path to a Mach-O file to class-dump.
  let machOFilePath: String
  /// The directory the class-dumped files should be created in.
  let outputDirectoryPath: String
}

/// Parses the arguments passed to this script. Aborts if invalid arguments are given.
func parseArguments(arguments: [String]) -> ClassDumpFormatterArguments {
  if arguments.count != 4 {
    print("Usage: ./ClassDumpFormatter.swift [path to class-dump executable] [path to Mach-O file] [path to output directory]")
    abort()
  }

  return ClassDumpFormatterArguments(
    classDumpExecutablePath: arguments[1],
    machOFilePath: arguments[2],
    outputDirectoryPath: arguments[3]
  )
}

// MARK: Main

// Parse arguments. Aborts if invalid arguments are given.
let arguments = parseArguments(Process.arguments)

// Create output directory if it doesn't already exist.
let fileManager = NSFileManager.defaultManager()
try fileManager.createDirectoryAtPath(arguments.outputDirectoryPath, withIntermediateDirectories: true, attributes: nil)

// class-dump and generate header for each file.
let output = try classDump(arguments.classDumpExecutablePath, machOFilePath: arguments.machOFilePath)
let lines: [NSString] = output.componentsSeparatedByNewlines()
let header = "\(lines.classDumpHeader)\n"
try fileManager.createFileForHeader(header, inDirectoryAtPath: arguments.outputDirectoryPath)

// For each protocol/class declaration in the dump...
lines.mapDeclarations { linesInDeclaration in
  // ...generate the file name...
  guard let firstLine = linesInDeclaration.first else {
    print("Error enumerating declarations.")
    abort()
  }
  let declarationName = firstLine.declarationName

  // ...create the declaration struct...
  let declaration = ClassDumpDeclaration(
    name: declarationName,
    header: header,
    declaration: linesInDeclaration.joinWithNewlines()
  )

  // ...and write it to a file.
  try! fileManager.createFileForDeclaration(declaration, inDirectoryAtPath: arguments.outputDirectoryPath)
}

