isPairedCharacter = require '../src/is-paired-character'

describe '.isPairedCharacter(string, index)', ->
  it 'returns true when the index is the start of a high/low surrogate pair, variation sequence, or combined character', ->
    expect(isPairedCharacter('a'.charCodeAt(0), '𝞗'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('𝞗'.charCodeAt(0), '𝞗'.charCodeAt(1))).toBe true
    expect(isPairedCharacter('𝞗'.charCodeAt(1), 'b'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('𝞗'.charCodeAt(1), null)).toBe false

    expect(isPairedCharacter('a'.charCodeAt(0), '✔︎'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('✔︎'.charCodeAt(0), '✔︎'.charCodeAt(1))).toBe true
    expect(isPairedCharacter('✔︎'.charCodeAt(1), 'b'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('✔︎'.charCodeAt(1), null)).toBe false

    expect(isPairedCharacter('a'.charCodeAt(0), 'é'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('é'.charCodeAt(0), 'é'.charCodeAt(1))).toBe true
    expect(isPairedCharacter('é'.charCodeAt(1), 'b'.charCodeAt(0))).toBe false
    expect(isPairedCharacter('é'.charCodeAt(1), null)).toBe false
