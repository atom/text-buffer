const Point = require('./point')
const {traverse, traversal, compare, max, isEqual} = require('./point-helpers')

const HARD_TAB = 1 << 0
const LEADING_WHITESPACE = 1 << 2
const TRAILING_WHITESPACE = 1 << 3
const INVISIBLE_CHARACTER = 1 << 4
const INDENT_GUIDE = 1 << 5
const LINE_ENDING = 1 << 6
const FOLD = 1 << 7

const basicTagCache = new Map()
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
    this.screenLines = []
    this.screenRow = screenStartRow
    this.bufferRow = this.displayLayer.translateScreenPosition(screenStart).row

    let hunkIndex = 0
    const hunks = this.displayLayer.spatialIndex.getHunksInNewRange(screenStart, screenEnd)
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

      // If the buffer line is empty, indent guides may extend beyond the line-ending
      // invisible, requiring this separate code path.
      while (this.bufferColumn <= this.bufferLine.length) {
        // Handle folds or soft wraps at the current position.
        let nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.oldStart.row < this.bufferRow) {
          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        while (nextHunk && nextHunk.oldStart.row === this.bufferRow && nextHunk.oldStart.column === this.bufferColumn) {
          if (nextHunk.newText === this.displayLayer.foldCharacter) {
            this.emitFold(nextHunk)
          // If the oldExtent of the hunk is zero, this is a soft line break.
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
        }

        // Compute the flags for the current token describing how it should be
        // decorated. If these flags differ from the previous token flags, emit
        // a close tag for those flags. Also emit a close tag at a forced token
        // boundary, such as between two hard tabs or where we want to show
        // an indent guide between spaces.
        let previousTokenFlags = this.currentTokenFlags
        this.currentTokenFlags = 0
        this.forceTokenBoundary = false
        if (nextCharacter === ' ' || nextCharacter === '\t') {
          this.updateCurrentTokenFlags(nextCharacter)
        } else {
          this.inLeadingWhitespace = false
        }

        if (previousTokenFlags > 0 &&
            (this.currentTokenFlags !== previousTokenFlags || this.forceTokenBoundary)) {
          this.emitCloseTag(this.getBasicTag(previousTokenFlags))
        }

        // We loop up to the end of the buffer line in case a fold starts there,
        // but at this point we haven't found a fold, so we can terminate the
        // screen line if we have reached the end of the buffer line.
        if (this.bufferColumn === this.bufferLine.length) {
          this.emitCloseTag(this.getBasicTag(this.currentTokenFlags))
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
          break
        }

        if (this.currentTokenFlags > 0 &&
            this.currentTokenFlags !== previousTokenFlags || this.forceTokenBoundary) {
          this.emitOpenTag(this.getBasicTag(this.currentTokenFlags))
        }

        // Handle tabs and leading / trailing whitespace invisibles specially.
        // Otherwise just append the next character to the screen line.
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

  getBasicTag (flags) {
    let tag = basicTagCache.get(flags)
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
      basicTagCache.set(flags, tag)
      return tag
    }
  }

  updateCurrentTokenFlags (nextCharacter) {
    const showIndentGuides = this.displayLayer.showIndentGuides && (this.inLeadingWhitespace || this.trailingWhitespaceStartColumn === 0)
    if (this.inLeadingWhitespace) this.currentTokenFlags |= LEADING_WHITESPACE
    if (this.inTrailingWhitespace) this.currentTokenFlags |= TRAILING_WHITESPACE

    if (nextCharacter === ' ') {
      if ((this.inLeadingWhitespace || this.inTrailingWhitespace) && this.displayLayer.invisibles.space) {
        this.currentTokenFlags |= INVISIBLE_CHARACTER
      }

      if (showIndentGuides) {
        this.currentTokenFlags |= INDENT_GUIDE
        if (this.screenColumn % this.displayLayer.tabLength === 0) this.forceTokenBoundary = true
      }
    } else { // nextCharacter === \t
      this.currentTokenFlags |= HARD_TAB
      if (this.displayLayer.invisibles.tab) this.currentTokenFlags |= INVISIBLE_CHARACTER
      if (showIndentGuides && this.screenColumn % this.displayLayer.tabLength === 0) {
        this.currentTokenFlags |= INDENT_GUIDE
      }

      this.forceTokenBoundary = true
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
      this.emitOpenTag(this.getBasicTag(eolFlags))
      this.emitText(eolInvisible)
      this.emitCloseTag(this.getBasicTag(eolFlags))
    }
  }

  emitIndentWhitespace (endColumn) {
    if (this.displayLayer.showIndentGuides) {
      let openedIndentGuide = false
      while (this.screenColumn < endColumn) {
        if (this.screenColumn % this.displayLayer.tabLength === 0) {
          if (openedIndentGuide) {
            this.emitCloseTag(this.getBasicTag(INDENT_GUIDE))
          }

          this.emitOpenTag(this.getBasicTag(INDENT_GUIDE))
          openedIndentGuide = true
        }
        this.emitText(' ')
      }

      if (openedIndentGuide) this.emitCloseTag(this.getBasicTag(INDENT_GUIDE))
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
    this.emitCloseTag(this.getBasicTag(this.currentTokenFlags))
    this.currentTokenFlags = 0

    this.emitOpenTag(this.getBasicTag(FOLD))
    this.emitText(this.displayLayer.foldCharacter)
    this.emitCloseTag(this.getBasicTag(FOLD))

    this.bufferRow = nextHunk.oldEnd.row
    this.bufferColumn = nextHunk.oldEnd.column
    this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
    this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
  }

  emitSoftWrap (nextHunk) {
    this.emitCloseTag(this.getBasicTag(this.currentTokenFlags))
    this.currentTokenFlags = 0
    this.emitNewline()
    this.emitIndentWhitespace(nextHunk.newEnd.column)
  }
}
