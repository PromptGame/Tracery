//
//  Parser.Gen2.swift
//  Tracery
//
//  Created by Benzi on 25/03/17.
//  Copyright © 2017 Benzi Ahamed. All rights reserved.
//

import Foundation


extension Parser {
    
    static func gen2(_ tokens: [Token]) throws -> [ParserNode] {
        return try gen2(tokens[0..<tokens.count])
    }
    
    // parses rules, tags, weights and plaintext
    static func gen2(_ tokens: ArraySlice<Token>) throws -> [ParserNode] {
        
        var index = tokens.startIndex
        var endIndex = tokens.endIndex
        
        func advance() {
            index += 1
        }
        
        var currentToken: Token? {
            return index < endIndex ? tokens[index] : nil
        }
        
        var nextToken: Token? {
            return index+1 < endIndex ? tokens[index+1] : nil
        }
        
        func parseOptionalText() -> String? {
            guard let token = currentToken, case let .text(text) = token else {
                return nil
            }
            advance()
            return text
        }
        
        func parseText(_ error: @autoclosure () -> String? = nil) throws -> String {
            guard let token = currentToken, case let .text(text) = token else {
                throw ParserError.error(error() ?? "expected text")
            }
            advance()
            return text
        }
        
        func parseRule() throws -> [ParserNode] {
            var nodes = [ParserNode]()
            
            try parse(.HASH)
            
            // a rule may contain sub rules
            // or tags
            while let token = currentToken, token == .LEFT_SQUARE_BRACKET {
                nodes.append(contentsOf: try parseTag())
            }
            
            // empty rule
            if currentToken == .HASH {
                try parse(.HASH)
                nodes.append(.text(""))
                return nodes
            }
            
            // lonely hash?
            if currentToken == nil {
                nodes.append(.text("#"))
                return nodes
            }
            
            let name = parseOptionalText() ?? ""
            
            var modifiers = [Modifier]()
            while let token = currentToken, token == .DOT {
                try parse(.DOT)
                let modName = try parseText("expected modifier name after . in rule '\(name)'")
                var params = [ValueCandidate]()
                if currentToken == .LEFT_ROUND_BRACKET {
                    try parse(.LEFT_ROUND_BRACKET)
                    let argsList = try parseFragmentList()
                    params = argsList.map {
                        return ValueCandidate.init(nodes: $0)
                    }
                    try parse(.RIGHT_ROUND_BRACKET, "expected ) to close modifier call")
                }
                modifiers.append(Modifier(name: modName, parameters: params))
            }
            
            nodes.append(ParserNode.rule(name: name, mods: modifiers))
            
            try parse(.HASH, "closing # not found for rule '\(name)'")
            
            return nodes
        }
        
        func parseTag() throws -> [ParserNode] {
            var nodes = [ParserNode]()
            try parse(.LEFT_SQUARE_BRACKET)
            scanning: while let token = currentToken {
                switch token {
                case Token.HASH:
                    nodes.append(contentsOf: try parseRule())
                case Token.LEFT_SQUARE_BRACKET:
                    nodes.append(contentsOf: try parseTag())
                case Token.RIGHT_SQUARE_BRACKET:
                    break scanning
                default:
                    let name = try parseText("expected tag name")
                    try parse(.COLON, "expected : after tag '\(name)'")
                    let values = try parseFragmentList()
                    if values[0].count == 0 {
                        throw ParserError.error("expected some value")
                    }
                    let tagValues = values.map { return ValueCandidate.init(nodes: $0) }
                    nodes.append(ParserNode.tag(name: name, values: tagValues))
                }
            }
            try parse(.RIGHT_SQUARE_BRACKET)
            return nodes
        }
        
        func parseWeight() throws -> [ParserNode] {
            var nodes = [ParserNode]()
            try parse(.COLON)
            // if there is a next token, and it is a number
            // then we have a weight, else treat colon as raw text
            guard let token = currentToken, case let .number(value) = token else {
                return [.text(":")]
            }
            advance() // since we can consume the number
            nodes.append(.weight(value: value))
            return nodes
        }
        
        func parseFragmentBlock() throws -> [ParserNode] {
            var block = [ParserNode]()
            while let fragment = try parseFragment() {
                block.append(contentsOf: fragment)
            }
            return block
        }
        
        
        func stripTrailingSpace(from nodes: inout [ParserNode]) {
            if let last = nodes.last, case let .text(content) = last {
                if content == " " {
                    nodes.removeLast()
                }
                else if content.hasSuffix(" ") {
                    nodes[nodes.count-1] = .text(content.substring(to: content.index(before: content.endIndex)))
                }
            }
        }

        func parseCondition() throws -> ParserCondition {
            var lhs = try parseFragmentBlock()
            stripTrailingSpace(from: &lhs)

            let op: ParserConditionOperator
            var rhs: [ParserNode]
            
            switch currentToken {
                
            case let x where x == Token.EQUAL_TO:
                advance()
                parseOptional(.SPACE)
                op = .equalTo
                rhs = try parseFragmentBlock()
                if rhs.count == 0 {
                    throw ParserError.error("expected rule or text after == in condition")
                }
                
                
            case let x where x == Token.NOT_EQUAL_TO:
                advance()
                parseOptional(.SPACE)
                op = .notEqualTo
                rhs = try parseFragmentBlock()
                if rhs.count == 0 {
                    throw ParserError.error("expected rule or text after != in condition")
                }
                
            case let x where x == Token.KEYWORD_IN || x == Token.KEYWORD_NOT_IN:
                advance()
                parseOptional(.SPACE)
                rhs = try parseFragmentBlock()
                // the rhs should evaluate to a single token
                // that is either a text or a rule
                if rhs.count > 0 {
                    if case .text = rhs[0] {
                        op = x == Token.KEYWORD_IN ? .equalTo : .notEqualTo
                    }
                    else {
                        op = x == Token.KEYWORD_IN ? .valueIn : .valueNotIn
                    }
                }
                else {
                    throw ParserError.error("expected rule after in/not in keyword")
                }
                
            default:
                rhs = [.text("")]
                op = .notEqualTo
            }
            
            stripTrailingSpace(from: &rhs)
            return ParserCondition.init(lhs: lhs, rhs: rhs, op: op)
        }
        
        func parseIfBlock() throws -> [ParserNode] {
            try parse(.LEFT_SQUARE_BRACKET)
            try parse(.KEYWORD_IF)
            try parse(.SPACE, "expected space after if")
            let condition = try parseCondition()
            try parse(.KEYWORD_THEN, "expected 'then' after condition")
            try parse(.SPACE, "expected space after 'then'")
            var thenBlock = try parseFragmentBlock()
            guard thenBlock.count > 0 else { throw ParserError.error("'then' must be followed by rule(s)") }
            var elseBlock:[ParserNode]? = nil
            if currentToken == .KEYWORD_ELSE {
                stripTrailingSpace(from: &thenBlock)
                try parse(.KEYWORD_ELSE)
                try parse(.SPACE, "expected space after else")
                let checkedElseBlock = try parseFragmentBlock()
                if checkedElseBlock.count > 0 {
                    elseBlock = checkedElseBlock
                }
                else {
                    throw ParserError.error("'else' must be followed by rule(s)")
                }
            }
            let block = ParserNode.ifBlock(condition: condition, thenBlock: thenBlock, elseBlock: elseBlock)
            try parse(.RIGHT_SQUARE_BRACKET)
            return [block]
        }
        
        func parseWhileBlock() throws -> [ParserNode] {
            try parse(.LEFT_SQUARE_BRACKET)
            try parse(.KEYWORD_WHILE)
            try parse(.SPACE, "expected space after while")
            let condition = try parseCondition()
            try parse(.KEYWORD_DO, "expected `do` in while after condition")
            try parse(.SPACE, "expected space after do in while")
            let doBlock = try parseFragmentBlock()
            guard doBlock.count > 0 else { throw ParserError.error("'do' must be followed by rule(s)") }
            let whileBlock = ParserNode.whileBlock(condition: condition, doBlock: doBlock)
            try parse(.RIGHT_SQUARE_BRACKET)
            return [whileBlock]
        }
        
        func parseFragmentList() throws -> [[ParserNode]] {
            var list = [[ParserNode]]()
            
            // list -> fragment more_fragments
            // more_fragments -> , fragment more_fragments | e
            func parseMoreFragments(list: inout [[ParserNode]]) throws {
                if currentToken != Token.COMMA { return }
                try parse(.COMMA)
                let moreFragments = try parseFragmentBlock()
                if moreFragments.count == 0 {
                    throw ParserError.error("expected value after ,")
                }
                list.append(moreFragments)
                try parseMoreFragments(list: &list)
            }
            
            let block = try parseFragmentBlock()
            list.append(block)
            try parseMoreFragments(list: &list)
            
            return list
        }
        
        func parse(_ token: Token, _ error: @autoclosure () -> String? = nil) throws {
            guard let c = currentToken else {
                throw ParserError.error(error() ?? "unexpected eof")
            }
            guard c == token else {
                throw ParserError.error(error() ?? "token mismatch expected \(token), got: \(c)")
            }
            advance()
        }
        
        func parseOptional(_ token: Token) {
            guard let c = currentToken, c == token else { return }
            advance()
        }
        
        func parseFragment() throws -> [ParserNode]? {
            var nodes = [ParserNode]()
            guard let token = currentToken else { return nil }
            
            switch token {
            
            case Token.HASH:
                nodes.append(contentsOf: try parseRule())

            case Token.LEFT_SQUARE_BRACKET:
                guard let next = nextToken else { return nil }
                switch next {
                case Token.KEYWORD_IF:
                    nodes.append(contentsOf: try parseIfBlock())
                case Token.KEYWORD_WHILE:
                    nodes.append(contentsOf: try parseWhileBlock())
                default:
                    nodes.append(contentsOf: try parseTag())
                }

            case Token.COLON:
                nodes.append(contentsOf: try parseWeight())
                
            case .text, .number:
                nodes.append(.text(token.rawText))
                advance()
                
            default:
                return nil
            
            }
            
            return nodes
        }
        
        
        var parsedNodes = [ParserNode]()
        
        while currentToken != nil {
            parsedNodes.append(contentsOf: try parseFragmentBlock())
            // at this stage, we may have consumed
            // all tokens, or reached a lone token that we can
            // treat as text
            if let token = currentToken {
                parsedNodes.append(.text(token.rawText))
                advance()
            }
        }
        
        return parsedNodes
        
    }
    
}