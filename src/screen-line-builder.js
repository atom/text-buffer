/* eslint-disable no-labels */

const Point = require('./point')

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

  buildScreenLines (startScreenRow, endScreenRow) {
    this.requestedStartScreenRow = startScreenRow
    this.requestedEndScreenRow = endScreenRow
    this.displayLayer.populateSpatialIndexIfNeeded(this.displayLayer.buffer.getLineCount(), endScreenRow)

    this.bufferRow = this.displayLayer.translateScreenPositionWithSpatialIndex(Point(startScreenRow, 0)).row
    this.bufferRow = this.displayLayer.findBoundaryPrecedingBufferRow(this.bufferRow)
    this.screenRow = this.displayLayer.translateBufferPositionWithSpatialIndex(Point(this.bufferRow, 0)).row

    endScreenRow = this.displayLayer.findBoundaryFollowingScreenRow(endScreenRow)

    let decorationIterator
    const hunks = this.displayLayer.spatialIndex.getHunksInNewRange(Point(this.screenRow, 0), Point(endScreenRow, 0))
    let hunkIndex = 0

    this.containingTags = []
    this.tagsToReopen = []
    this.screenLines = []
    this.bufferColumn = 0
    this.beginLine()

    // Loop through all characters spanning the given screen row range, building
    // up screen lines based on the contents of the spatial index and the
    // buffer.
    screenRowLoop:
    while (this.screenRow < endScreenRow) {
      const cachedScreenLine = this.displayLayer.cachedScreenLines[this.screenRow]
      if (cachedScreenLine) {
        this.pushScreenLine(cachedScreenLine)

        let nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.newStart.row <= this.screenRow) {
          if (nextHunk.newStart.row === this.screenRow) {
            if (nextHunk.newEnd.row > nextHunk.newStart.row) {
              this.screenRow++
              hunkIndex++
              continue screenRowLoop
            } else {
              this.bufferRow = nextHunk.oldEnd.row
            }
          }

          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        this.screenRow++
        this.bufferRow++
        this.screenColumn = 0
        this.bufferColumn = 0
        continue
      }

      this.currentBuiltInTagFlags = 0
      this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
      if (this.bufferLine == null) break
      this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
      this.inLeadingWhitespace = true
      this.inTrailingWhitespace = false

      if (!decorationIterator) {
        decorationIterator = this.displayLayer.textDecorationLayer.buildIterator()
        this.tagsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))
      } else if (this.compareBufferPosition(decorationIterator.getPosition()) > 0) {
        this.tagsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))
      }

      // This loop may visit multiple buffer rows if there are folds and
      // multiple screen rows if there are soft wraps.
      while (this.bufferColumn <= this.bufferLine.length) {
        // Handle folds or soft wraps at the current position.
        let nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.oldStart.row === this.bufferRow && nextHunk.oldStart.column === this.bufferColumn) {
          if (this.displayLayer.isSoftWrapHunk(nextHunk)) {
            this.emitSoftWrap(nextHunk)
          } else {
            this.emitFold(nextHunk, decorationIterator)
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
        const previousBuiltInTagFlags = this.currentBuiltInTagFlags
        this.updateCurrentTokenFlags(nextCharacter)

        if (this.emitBuiltInTagBoundary) {
          this.emitCloseTag(this.getBuiltInTag(previousBuiltInTagFlags))
        }

        this.emitDecorationBoundaries(decorationIterator)

        // Are we at the end of the line?
        if (this.bufferColumn === this.bufferLine.length) {
          this.emitLineEnding()
          break
        }

        if (this.emitBuiltInTagBoundary) {
          this.emitOpenTag(this.getBuiltInTag(this.currentBuiltInTagFlags))
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

  beginLine () {
    this.currentScreenLineText = ''
    this.currentScreenLineTagCodes = []
    this.screenColumn = 0
    this.currentTokenLength = 0
  }

  updateCurrentTokenFlags (nextCharacter) {
    const previousBuiltInTagFlags = this.currentBuiltInTagFlags
    this.currentBuiltInTagFlags = 0
    this.emitBuiltInTagBoundary = false

    if (nextCharacter === ' ' || nextCharacter === '\t') {
      const showIndentGuides = this.displayLayer.showIndentGuides && (this.inLeadingWhitespace || this.trailingWhitespaceStartColumn === 0)
      if (this.inLeadingWhitespace) this.currentBuiltInTagFlags |= LEADING_WHITESPACE
      if (this.inTrailingWhitespace) this.currentBuiltInTagFlags |= TRAILING_WHITESPACE

      if (nextCharacter === ' ') {
        if ((this.inLeadingWhitespace || this.inTrailingWhitespace) && this.displayLayer.invisibles.space) {
          this.currentBuiltInTagFlags |= INVISIBLE_CHARACTER
        }

        if (showIndentGuides) {
          this.currentBuiltInTagFlags |= INDENT_GUIDE
          if (this.screenColumn % this.displayLayer.tabLength === 0) this.emitBuiltInTagBoundary = true
        }
      } else { // nextCharacter === \t
        this.currentBuiltInTagFlags |= HARD_TAB
        if (this.displayLayer.invisibles.tab) this.currentBuiltInTagFlags |= INVISIBLE_CHARACTER
        if (showIndentGuides && this.screenColumn % this.displayLayer.tabLength === 0) {
          this.currentBuiltInTagFlags |= INDENT_GUIDE
        }

        this.emitBuiltInTagBoundary = true
      }
    }

    if (!this.emitBuiltInTagBoundary) {
      this.emitBuiltInTagBoundary = this.currentBuiltInTagFlags !== previousBuiltInTagFlags
    }
  }

  emitDecorationBoundaries (decorationIterator) {
    while (this.compareBufferPosition(decorationIterator.getPosition()) === 0) {
      const closeTags = decorationIterator.getCloseTags()
      for (let i = 0, n = closeTags.length; i < n; i++) {
        this.emitCloseTag(closeTags[i])
      }

      const openTags = decorationIterator.getOpenTags()
      for (let i = 0, n = openTags.length; i < n; i++) {
        this.emitOpenTag(openTags[i])
      }

      decorationIterator.moveToSuccessor()
    }
  }

  emitFold (nextHunk, decorationIterator) {
    this.emitCloseTag(this.getBuiltInTag(this.currentBuiltInTagFlags))
    this.currentBuiltInTagFlags = 0

    this.closeContainingTags()
    this.tagsToReopen.length = 0

    this.emitOpenTag(this.getBuiltInTag(FOLD))
    this.emitText(this.displayLayer.foldCharacter)
    this.emitCloseTag(this.getBuiltInTag(FOLD))

    this.bufferRow = nextHunk.oldEnd.row
    this.bufferColumn = nextHunk.oldEnd.column

    this.tagsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))

    this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
    this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
  }

  emitSoftWrap (nextHunk) {
    this.emitCloseTag(this.getBuiltInTag(this.currentBuiltInTagFlags))
    this.currentBuiltInTagFlags = 0
    this.closeContainingTags()
    this.emitNewline()
    this.emitIndentWhitespace(nextHunk.newEnd.column)
  }

  emitLineEnding () {
    this.emitCloseTag(this.getBuiltInTag(this.currentBuiltInTagFlags))

    let lineEnding = this.displayLayer.buffer.lineEndingForRow(this.bufferRow)
    const eolInvisible = this.displayLayer.eolInvisibles[lineEnding]
    if (eolInvisible) {
      let eolFlags = INVISIBLE_CHARACTER | LINE_ENDING
      if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) eolFlags |= INDENT_GUIDE
      this.emitOpenTag(this.getBuiltInTag(eolFlags))
      this.emitText(eolInvisible, false)
      this.emitCloseTag(this.getBuiltInTag(eolFlags))
    }

    if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) {
      let whitespaceLength = this.displayLayer.leadingWhitespaceLengthForSurroundingLines(this.bufferRow)
      this.emitIndentWhitespace(whitespaceLength)
    }

    this.closeContainingTags()

    // Ensure empty lines have at least one empty token to make it easier on
    // the caller
    if (this.currentScreenLineTagCodes.length === 0) this.currentScreenLineTagCodes.push(0)
    this.emitNewline()
    this.bufferRow++
    this.bufferColumn = 0
  }

  emitNewline () {
    const screenLine = {
      id: nextScreenLineId++,
      lineText: this.currentScreenLineText,
      tagCodes: this.currentScreenLineTagCodes
    }
    this.pushScreenLine(screenLine)
    this.displayLayer.cachedScreenLines[this.screenRow] = screenLine
    this.screenRow++
    this.beginLine()
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
        this.emitText(' ', false)
      }

      if (openedIndentGuide) this.emitCloseTag(this.getBuiltInTag(INDENT_GUIDE))
    } else {
      this.emitText(' '.repeat(endColumn - this.screenColumn), false)
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

  emitText (text, reopenTags = true) {
    if (reopenTags) this.reopenTags()
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

  emitEmptyTokenIfNeeded () {
    const lastTagCode = this.currentScreenLineTagCodes[this.currentScreenLineTagCodes.length - 1]
    if (this.displayLayer.isOpenTagCode(lastTagCode)) {
      this.currentScreenLineTagCodes.push(0)
    }
  }

  emitCloseTag (closeTag) {
    this.emitTokenBoundary()

    if (closeTag.length === 0) return

    for (let i = this.tagsToReopen.length - 1; i >= 0; i--) {
      if (this.tagsToReopen[i] === closeTag) {
        this.tagsToReopen.splice(i, 1)
        return
      }
    }

    this.emitEmptyTokenIfNeeded()

    let containingTag
    while ((containingTag = this.containingTags.pop())) {
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForCloseTag(containingTag))
      if (containingTag === closeTag) {
        return
      } else {
        this.tagsToReopen.unshift(containingTag)
      }
    }
  }

  emitOpenTag (openTag, reopenTags = true) {
    if (reopenTags) this.reopenTags()
    this.emitTokenBoundary()
    if (openTag.length > 0) {
      this.containingTags.push(openTag)
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForOpenTag(openTag))
    }
  }

  closeContainingTags () {
    if (this.containingTags.length > 0) this.emitEmptyTokenIfNeeded()

    for (let i = this.containingTags.length - 1; i >= 0; i--) {
      const containingTag = this.containingTags[i]
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForCloseTag(containingTag))
      this.tagsToReopen.unshift(containingTag)
    }
    this.containingTags.length = 0
  }

  reopenTags () {
    for (let i = 0, n = this.tagsToReopen.length; i < n; i++) {
      const tagToReopen = this.tagsToReopen[i]
      this.containingTags.push(tagToReopen)
      this.currentScreenLineTagCodes.push(this.displayLayer.codeForOpenTag(tagToReopen))
    }
    this.tagsToReopen.length = 0
  }

  pushScreenLine (screenLine) {
    if (this.requestedStartScreenRow <= this.screenRow && this.screenRow < this.requestedEndScreenRow) {
      this.screenLines.push(screenLine)
    }
  }

  compareBufferPosition (position) {
    if (this.bufferRow < position.row) {
      return -1
    } else if (this.bufferRow === position.row) {
      if (this.bufferColumn < position.column) {
        return -1
      } else if (this.bufferColumn === position.column) {
        return 0
      } else {
        return 1
      }
    } else {
      return 1
    }
  }
}
