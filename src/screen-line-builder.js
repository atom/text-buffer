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
    let screenLines = []
    let screenRow = screenStartRow
    let {row: bufferRow} = this.displayLayer.translateScreenPosition(screenStart)

    let hunkIndex = 0
    const hunks = this.displayLayer.spatialIndex.getHunksInNewRange(screenStart, screenEnd)
    while (screenRow < screenEndRow) {
      this.currentScreenLineText = ''
      this.currentScreenLineTagCodes = []
      this.currentTokenLength = 0
      this.screenColumn = 0
      let currentTokenFlags = 0
      let bufferLine = this.displayLayer.buffer.lineForRow(bufferRow)
      let lineEnding = this.displayLayer.buffer.lineEndingForRow(bufferRow)
      let bufferColumn = 0
      let trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(bufferLine)
      let inLeadingWhitespace = true
      let inTrailingWhitespace = false

      // If the buffer line is empty, indent guides may extend beyond the line-ending
      // invisible, requiring this separate code path.
      while (bufferColumn <= bufferLine.length) {
        // Handle folds or soft wraps at the current position.
        let nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.oldStart.row < bufferRow) {
          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        while (nextHunk && nextHunk.oldStart.row === bufferRow && nextHunk.oldStart.column === bufferColumn) {
          // Does a fold hunk start here? Jump to the end of the fold and
          // continue to the next iteration of the loop.
          if (nextHunk.newText === this.displayLayer.foldCharacter) {
            this.emitCloseTag(this.getBasicTag(currentTokenFlags))
            currentTokenFlags = 0

            this.emitOpenTag(this.getBasicTag(FOLD))
            this.emitText(this.displayLayer.foldCharacter)
            this.emitCloseTag(this.getBasicTag(FOLD))

            bufferRow = nextHunk.oldEnd.row
            bufferColumn = nextHunk.oldEnd.column
            bufferLine = this.displayLayer.buffer.lineForRow(bufferRow)
            inTrailingWhitespace = false
            trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(bufferLine)

          // If the oldExtent of the hunk is zero, this is a soft line break.
          } else if (isEqual(nextHunk.oldStart, nextHunk.oldEnd)) {
            this.emitCloseTag(this.getBasicTag(currentTokenFlags))
            currentTokenFlags = 0

            const screenLine = {id: nextScreenLineId++, lineText: this.currentScreenLineText, tagCodes: this.currentScreenLineTagCodes}
            screenLines.push(screenLine)
            screenRow++
            this.currentScreenLineText = ''
            this.currentScreenLineTagCodes = []
            this.screenColumn = 0

            // Make indent of soft-wrapped segment match the indent of the
            // original line, rendering indent guides if necessary.
            const indentLength = nextHunk.newEnd.column
            if (this.displayLayer.showIndentGuides) {
              let openedIndentGuide = false
              while (this.screenColumn < indentLength) {
                if (this.screenColumn % this.displayLayer.tabLength === 0) {
                  if (openedIndentGuide) this.emitCloseTag(this.getBasicTag(INDENT_GUIDE))
                  this.emitOpenTag(this.getBasicTag(INDENT_GUIDE))
                  openedIndentGuide = true
                }
                this.emitText(' ')
              }
              if (openedIndentGuide) this.emitCloseTag(this.getBasicTag(INDENT_GUIDE))
            } else {
              this.emitText(' '.repeat(indentLength))
            }
          }

          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        const nextCharacter = bufferLine[bufferColumn]
        if (bufferColumn >= trailingWhitespaceStartColumn) {
          inTrailingWhitespace = true
          inLeadingWhitespace = false
        }

        // Compute the flags for the current token describing how it should be
        // decorated. If these flags differ from the previous token flags, emit
        // a close tag for those flags. Also emit a close tag at a forced token
        // boundary, such as between two hard tabs or where we want to show
        // an indent guide between spaces.
        let forceTokenBoundary = false
        let previousTokenFlags = currentTokenFlags
        currentTokenFlags = 0

        if (nextCharacter === ' ' || nextCharacter === '\t') {
          const showIndentGuides = this.displayLayer.showIndentGuides && (inLeadingWhitespace || trailingWhitespaceStartColumn === 0)
          if (inLeadingWhitespace) currentTokenFlags |= LEADING_WHITESPACE
          if (inTrailingWhitespace) currentTokenFlags |= TRAILING_WHITESPACE

          if (nextCharacter === ' ') {
            if ((inLeadingWhitespace || inTrailingWhitespace) && this.displayLayer.invisibles.space) {
              currentTokenFlags |= INVISIBLE_CHARACTER
            }

            if (showIndentGuides) {
              currentTokenFlags |= INDENT_GUIDE
              if (this.screenColumn % this.displayLayer.tabLength === 0) forceTokenBoundary = true
            }
          } else { // nextCharacter === \t
            currentTokenFlags |= HARD_TAB
            if (this.displayLayer.invisibles.tab) currentTokenFlags |= INVISIBLE_CHARACTER
            if (showIndentGuides && this.screenColumn % this.displayLayer.tabLength === 0) {
              currentTokenFlags |= INDENT_GUIDE
            }

            forceTokenBoundary = true
          }
        } else {
          inLeadingWhitespace = false
        }

        if (previousTokenFlags > 0 &&
            (currentTokenFlags !== previousTokenFlags || forceTokenBoundary)) {
          this.emitCloseTag(this.getBasicTag(previousTokenFlags))
        }

        // We loop up to the end of the buffer line in case a fold starts there,
        // but at this point we haven't found a fold, so we can stop if we have
        // reached the end of the line. We need to close any open tags and
        // append the line ending invisible if it is enabled, then break the
        // loop to proceed to the next line. If the line is empty, we may need
        // to render indent guides that extend beyond the length of the line.
        if (bufferColumn === bufferLine.length) {
          this.emitCloseTag(this.getBasicTag(currentTokenFlags))

          const eolInvisible = this.displayLayer.eolInvisibles[lineEnding]
          if (eolInvisible) {
            let eolFlags = INVISIBLE_CHARACTER | LINE_ENDING
            if (bufferLine.length === 0 && this.displayLayer.showIndentGuides) eolFlags |= INDENT_GUIDE
            this.emitOpenTag(this.getBasicTag(eolFlags))
            this.emitText(eolInvisible)
            this.emitCloseTag(this.getBasicTag(eolFlags))
          }

          if (bufferLine.length === 0 && this.displayLayer.showIndentGuides) {
            let whitespaceLength = this.displayLayer.leadingWhitespaceLengthForSurroundingLines(bufferRow)
            let openedIndentGuide = false
            while (this.screenColumn < whitespaceLength) {
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
          }

          // Ensure empty lines have at least one empty token to make it easier on
          // the caller
          if (this.currentScreenLineTagCodes.length === 0) this.currentScreenLineTagCodes.push(0)

          break
        }

        // At this point we know we aren't at the end of the line, so we proceed
        // to process the next character.

        // If the current token's flags differ from the previous iteration or
        // we are forcing a token boundary (for example between two hard tabs),
        // push an open tag based on the new flags.
        if (currentTokenFlags > 0 &&
            currentTokenFlags !== previousTokenFlags || forceTokenBoundary) {
          this.emitOpenTag(this.getBasicTag(currentTokenFlags))
        }

        // Handle tabs and leading / trailing whitespace invisibles specially.
        // Otherwise just append the next character to the screen line.
        if (nextCharacter === '\t') {
          this.currentTokenLength = 0
          const distanceToNextTabStop = this.displayLayer.tabLength - (this.screenColumn % this.displayLayer.tabLength)
          if (this.displayLayer.invisibles.tab) {
            this.emitText(this.displayLayer.invisibles.tab)
            this.emitText(' '.repeat(distanceToNextTabStop - 1))
          } else {
            this.emitText(' '.repeat(distanceToNextTabStop))
          }
        } else {
          if ((inLeadingWhitespace || inTrailingWhitespace) &&
              nextCharacter === ' ' && this.displayLayer.invisibles.space) {
            this.emitText(this.displayLayer.invisibles.space)
          } else {
            this.emitText(nextCharacter)
          }
        }
        bufferColumn++
      }

      const screenLine = {id: nextScreenLineId++, lineText: this.currentScreenLineText, tagCodes: this.currentScreenLineTagCodes}
      screenLines.push(screenLine)
      screenRow++
      bufferRow++
    }

    return screenLines
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
}
