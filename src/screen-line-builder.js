const Point = require('./point')
const {traverse, traversal, compare, max, isEqual} = require('./point-helpers')

const HARD_TAB = 1 << 0
const LEADING_WHITESPACE = 1 << 2
const TRAILING_WHITESPACE = 1 << 3
const INVISIBLE_CHARACTER = 1 << 4
const INDENT_GUIDE = 1 << 5
const LINE_ENDING = 1 << 6
const FOLD = 1 << 7

const builtInTagCache = new Map()
let nextScreenLineId = 1

module.exports =
class ScreenLineBuilder {
  constructor (displayLayer) {
    this.displayLayer = displayLayer
  }

  buildScreenLines (screenStartRow, screenEndRow) {
    screenEndRow = Math.min(screenEndRow, this.displayLayer.getScreenLineCount())
    const screenStart = Point(screenStartRow, 0)
    const screenEnd = Point(screenEndRow, 0)
    const hunks = this.displayLayer.spatialIndex.getHunksInNewRange(screenStart, screenEnd)
    let hunkIndex = 0

    this.screenLines = []
    this.screenRow = screenStartRow
    this.bufferRow = this.displayLayer.translateScreenPosition(screenStart).row

    // Loop through all characters spanning the given screen row range, building
    // up screen lines based on the contents of the spatial index and the
    // buffer.
    while (this.screenRow < screenEndRow) {
      this.currentScreenLineText = ''
      this.currentScreenLineTagCodes = []
      this.currentTokenLength = 0
      this.screenColumn = 0
      this.currentTokenFlags = 0
      this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
      this.bufferColumn = 0
      this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
      this.inLeadingWhitespace = true
      this.inTrailingWhitespace = false

      // This loop may visit multiple buffer rows if there are folds and
      // multiple screen rows if there are soft wraps.
      while (this.bufferColumn <= this.bufferLine.length) {
        // Discard hunks starting before the current row
        let nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.oldStart.row < this.bufferRow) {
          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        // Handle folds or soft wraps at the current position.
        while (nextHunk && nextHunk.oldStart.row === this.bufferRow && nextHunk.oldStart.column === this.bufferColumn) {
          if (nextHunk.newText === this.displayLayer.foldCharacter) {
            this.emitFold(nextHunk)
          } else if (isEqual(nextHunk.oldStart, nextHunk.oldEnd)) {
            this.emitSoftWrap(nextHunk)
          }

          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        const nextCharacter = this.bufferLine[this.bufferColumn]
        if (this.bufferColumn >= this.trailingWhitespaceStartColumn) {
          this.inTrailingWhitespace = true
          this.inLeadingWhitespace = false
        } else if (nextCharacter !== ' ' && nextCharacter !== '\t') {
          this.inLeadingWhitespace = false
        }

        // Compute a token flags describing built-in decorations for the token
        // containing the next character
        const previousTokenFlags = this.currentTokenFlags
        this.updateCurrentTokenFlags(nextCharacter)

        if (this.emitBuiltInTagBoundary) {
          this.emitCloseTag(this.getBuiltInTag(previousTokenFlags))
        }

        // Are we at the end of the line?
        if (this.bufferColumn === this.bufferLine.length) {
          this.emitLineEnding()
          break
        }

        if (this.emitBuiltInTagBoundary) {
          this.emitOpenTag(this.getBuiltInTag(this.currentTokenFlags))
        }

        // Emit the next character, handling hard tabs whitespace invisibles
        // specially.
        if (nextCharacter === '\t') {
          this.emitHardTab()
        } else if ((this.inLeadingWhitespace || this.inTrailingWhitespace) &&
                    nextCharacter === ' ' && this.displayLayer.invisibles.space) {
          this.emitText(this.displayLayer.invisibles.space)
        } else {
          this.emitText(nextCharacter)
        }
        this.bufferColumn++
      }
    }

    return this.screenLines
  }

  getBuiltInTag (flags) {
    let tag = builtInTagCache.get(flags)
    if (tag) {
      return tag
    } else {
      let tag = ''
      if (flags & INVISIBLE_CHARACTER) tag += 'invisible-character '
      if (flags & HARD_TAB) tag += 'hard-tab '
      if (flags & LEADING_WHITESPACE) tag += 'leading-whitespace '
      if (flags & TRAILING_WHITESPACE) tag += 'trailing-whitespace '
      if (flags & LINE_ENDING) tag += 'eol '
      if (flags & INDENT_GUIDE) tag += 'indent-guide '
      if (flags & FOLD) tag += 'fold-marker '
      tag = tag.trim()
      builtInTagCache.set(flags, tag)
      return tag
    }
  }

  updateCurrentTokenFlags (nextCharacter) {
    const previousTokenFlags = this.currentTokenFlags
    this.currentTokenFlags = 0
    this.emitBuiltInTagBoundary = false

    if (nextCharacter === ' ' || nextCharacter === '\t') {
      const showIndentGuides = this.displayLayer.showIndentGuides && (this.inLeadingWhitespace || this.trailingWhitespaceStartColumn === 0)
      if (this.inLeadingWhitespace) this.currentTokenFlags |= LEADING_WHITESPACE
      if (this.inTrailingWhitespace) this.currentTokenFlags |= TRAILING_WHITESPACE

      if (nextCharacter === ' ') {
        if ((this.inLeadingWhitespace || this.inTrailingWhitespace) && this.displayLayer.invisibles.space) {
          this.currentTokenFlags |= INVISIBLE_CHARACTER
        }

        if (showIndentGuides) {
          this.currentTokenFlags |= INDENT_GUIDE
          if (this.screenColumn % this.displayLayer.tabLength === 0) this.emitBuiltInTagBoundary = true
        }
      } else { // nextCharacter === \t
        this.currentTokenFlags |= HARD_TAB
        if (this.displayLayer.invisibles.tab) this.currentTokenFlags |= INVISIBLE_CHARACTER
        if (showIndentGuides && this.screenColumn % this.displayLayer.tabLength === 0) {
          this.currentTokenFlags |= INDENT_GUIDE
        }

        this.emitBuiltInTagBoundary = true
      }
    }

    if (!this.emitBuiltInTagBoundary) {
      this.emitBuiltInTagBoundary = this.currentTokenFlags !== previousTokenFlags
    }
  }

  emitText (text) {
    this.currentScreenLineText += text
    const length = text.length
    this.screenColumn += length
    this.currentTokenLength += length
  }

  emitTokenBoundary () {
    if (this.currentTokenLength > 0) {
      this.currentScreenLineTagCodes.push(this.currentTokenLength)
      this.currentTokenLength = 0
    }
  }

  emitCloseTag (closeTag) {
    this.emitTokenBoundary()
    if (closeTag.length > 0) {
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForCloseTag(closeTag))
    }
  }

  emitOpenTag (openTag) {
    this.emitTokenBoundary()
    if (openTag.length > 0) {
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForOpenTag(openTag))
    }
  }

  emitLineEnding () {
    this.emitCloseTag(this.getBuiltInTag(this.currentTokenFlags))
    this.emitEOLInvisible()
    if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) {
      let whitespaceLength = this.displayLayer.leadingWhitespaceLengthForSurroundingLines(this.bufferRow)
      this.emitIndentWhitespace(whitespaceLength)
    }
    // Ensure empty lines have at least one empty token to make it easier on
    // the caller
    if (this.currentScreenLineTagCodes.length === 0) this.currentScreenLineTagCodes.push(0)
    this.emitNewline()
    this.bufferRow++
  }

  emitNewline () {
    this.screenLines.push({
      id: nextScreenLineId++,
      lineText: this.currentScreenLineText,
      tagCodes: this.currentScreenLineTagCodes
    })
    this.screenRow++
    this.currentScreenLineText = ''
    this.currentScreenLineTagCodes = []
    this.screenColumn = 0
  }

  emitEOLInvisible () {
    let lineEnding = this.displayLayer.buffer.lineEndingForRow(this.bufferRow)
    const eolInvisible = this.displayLayer.eolInvisibles[lineEnding]
    if (eolInvisible) {
      let eolFlags = INVISIBLE_CHARACTER | LINE_ENDING
      if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) eolFlags |= INDENT_GUIDE
      this.emitOpenTag(this.getBuiltInTag(eolFlags))
      this.emitText(eolInvisible)
      this.emitCloseTag(this.getBuiltInTag(eolFlags))
    }
  }

  emitIndentWhitespace (endColumn) {
    if (this.displayLayer.showIndentGuides) {
      let openedIndentGuide = false
      while (this.screenColumn < endColumn) {
        if (this.screenColumn % this.displayLayer.tabLength === 0) {
          if (openedIndentGuide) {
            this.emitCloseTag(this.getBuiltInTag(INDENT_GUIDE))
          }

          this.emitOpenTag(this.getBuiltInTag(INDENT_GUIDE))
          openedIndentGuide = true
        }
        this.emitText(' ')
      }

      if (openedIndentGuide) this.emitCloseTag(this.getBuiltInTag(INDENT_GUIDE))
    } else {
      this.emitText(' '.repeat(endColumn - this.screenColumn))
    }
  }

  emitHardTab () {
    const distanceToNextTabStop = this.displayLayer.tabLength - (this.screenColumn % this.displayLayer.tabLength)
    if (this.displayLayer.invisibles.tab) {
      this.emitText(this.displayLayer.invisibles.tab)
      this.emitText(' '.repeat(distanceToNextTabStop - 1))
    } else {
      this.emitText(' '.repeat(distanceToNextTabStop))
    }
  }

  emitFold (nextHunk) {
    this.emitCloseTag(this.getBuiltInTag(this.currentTokenFlags))
    this.currentTokenFlags = 0

    this.emitOpenTag(this.getBuiltInTag(FOLD))
    this.emitText(this.displayLayer.foldCharacter)
    this.emitCloseTag(this.getBuiltInTag(FOLD))

    this.bufferRow = nextHunk.oldEnd.row
    this.bufferColumn = nextHunk.oldEnd.column
    this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
    this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
  }

  emitSoftWrap (nextHunk) {
    this.emitCloseTag(this.getBuiltInTag(this.currentTokenFlags))
    this.currentTokenFlags = 0
    this.emitNewline()
    this.emitIndentWhitespace(nextHunk.newEnd.column)
  }
}
