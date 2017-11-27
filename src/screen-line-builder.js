/* eslint-disable no-labels */

const Point = require('./point')

const HARD_TAB = 1 << 0
const LEADING_WHITESPACE = 1 << 2
const TRAILING_WHITESPACE = 1 << 3
const INVISIBLE_CHARACTER = 1 << 4
const INDENT_GUIDE = 1 << 5
const LINE_ENDING = 1 << 6
const FOLD = 1 << 7

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
    const hunks = this.displayLayer.spatialIndex.getChangesInNewRange(Point(this.screenRow, 0), Point(endScreenRow, 0))
    let hunkIndex = 0

    this.containingScopeIds = []
    this.scopeIdsToReopen = []
    this.screenLines = []
    this.bufferColumn = 0
    this.beginLine()

    // Loop through all characters spanning the given screen row range, building
    // up screen lines based on the contents of the spatial index and the
    // buffer.
    screenRowLoop:
    while (this.screenRow < endScreenRow) {
      var cachedScreenLine = this.displayLayer.cachedScreenLines[this.screenRow]
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

      this.currentBuiltInClassNameFlags = 0
      this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
      if (this.bufferLine == null) break
      this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
      this.inLeadingWhitespace = true
      this.inTrailingWhitespace = false

      if (!decorationIterator) {
        decorationIterator = this.displayLayer.buffer.languageMode.buildHighlightIterator()
        this.scopeIdsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))
      } else if (this.compareBufferPosition(decorationIterator.getPosition()) > 0) {
        this.scopeIdsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))
      }

      // This loop may visit multiple buffer rows if there are folds and
      // multiple screen rows if there are soft wraps.
      while (this.bufferColumn <= this.bufferLine.length) {
        // Handle folds or soft wraps at the current position.
        var nextHunk = hunks[hunkIndex]
        while (nextHunk && nextHunk.oldStart.row === this.bufferRow && nextHunk.oldStart.column === this.bufferColumn) {
          if (this.displayLayer.isSoftWrapHunk(nextHunk)) {
            this.emitSoftWrap(nextHunk)
          } else {
            this.emitFold(nextHunk, decorationIterator)
          }

          hunkIndex++
          nextHunk = hunks[hunkIndex]
        }

        var nextCharacter = this.bufferLine[this.bufferColumn]
        if (this.bufferColumn >= this.trailingWhitespaceStartColumn) {
          this.inTrailingWhitespace = true
          this.inLeadingWhitespace = false
        } else if (nextCharacter !== ' ' && nextCharacter !== '\t') {
          this.inLeadingWhitespace = false
        }

        // Compute a token flags describing built-in decorations for the token
        // containing the next character
        var previousBuiltInTagFlags = this.currentBuiltInClassNameFlags
        this.updateCurrentTokenFlags(nextCharacter)

        if (this.emitBuiltInTagBoundary) {
          this.emitCloseTag(this.getBuiltInScopeId(previousBuiltInTagFlags))
        }

        this.emitDecorationBoundaries(decorationIterator)

        // Are we at the end of the line?
        if (this.bufferColumn === this.bufferLine.length) {
          this.emitLineEnding()
          break
        }

        if (this.emitBuiltInTagBoundary) {
          this.emitOpenTag(this.getBuiltInScopeId(this.currentBuiltInClassNameFlags))
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

  getBuiltInScopeId (flags) {
    if (flags === 0) return 0

    let scopeId = this.displayLayer.getBuiltInScopeId(flags)
    if (scopeId === -1) {
      let className = ''
      if (flags & INVISIBLE_CHARACTER) className += 'invisible-character '
      if (flags & HARD_TAB) className += 'hard-tab '
      if (flags & LEADING_WHITESPACE) className += 'leading-whitespace '
      if (flags & TRAILING_WHITESPACE) className += 'trailing-whitespace '
      if (flags & LINE_ENDING) className += 'eol '
      if (flags & INDENT_GUIDE) className += 'indent-guide '
      if (flags & FOLD) className += 'fold-marker '
      className = className.trim()
      scopeId = this.displayLayer.registerBuiltInScope(flags, className)
    }
    return scopeId
  }

  beginLine () {
    this.currentScreenLineText = ''
    this.currentScreenLineTags = []
    this.screenColumn = 0
    this.currentTokenLength = 0
  }

  updateCurrentTokenFlags (nextCharacter) {
    const previousBuiltInTagFlags = this.currentBuiltInClassNameFlags
    this.currentBuiltInClassNameFlags = 0
    this.emitBuiltInTagBoundary = false

    if (nextCharacter === ' ' || nextCharacter === '\t') {
      const showIndentGuides = this.displayLayer.showIndentGuides && (this.inLeadingWhitespace || this.trailingWhitespaceStartColumn === 0)
      if (this.inLeadingWhitespace) this.currentBuiltInClassNameFlags |= LEADING_WHITESPACE
      if (this.inTrailingWhitespace) this.currentBuiltInClassNameFlags |= TRAILING_WHITESPACE

      if (nextCharacter === ' ') {
        if ((this.inLeadingWhitespace || this.inTrailingWhitespace) && this.displayLayer.invisibles.space) {
          this.currentBuiltInClassNameFlags |= INVISIBLE_CHARACTER
        }

        if (showIndentGuides) {
          this.currentBuiltInClassNameFlags |= INDENT_GUIDE
          if (this.screenColumn % this.displayLayer.tabLength === 0) this.emitBuiltInTagBoundary = true
        }
      } else { // nextCharacter === \t
        this.currentBuiltInClassNameFlags |= HARD_TAB
        if (this.displayLayer.invisibles.tab) this.currentBuiltInClassNameFlags |= INVISIBLE_CHARACTER
        if (showIndentGuides && this.screenColumn % this.displayLayer.tabLength === 0) {
          this.currentBuiltInClassNameFlags |= INDENT_GUIDE
        }

        this.emitBuiltInTagBoundary = true
      }
    }

    if (!this.emitBuiltInTagBoundary) {
      this.emitBuiltInTagBoundary = this.currentBuiltInClassNameFlags !== previousBuiltInTagFlags
    }
  }

  emitDecorationBoundaries (decorationIterator) {
    while (this.compareBufferPosition(decorationIterator.getPosition()) === 0) {
      var closeScopeIds = decorationIterator.getCloseScopeIds()
      for (let i = 0, n = closeScopeIds.length; i < n; i++) {
        this.emitCloseTag(closeScopeIds[i])
      }

      var openScopeIds = decorationIterator.getOpenScopeIds()
      for (let i = 0, n = openScopeIds.length; i < n; i++) {
        this.emitOpenTag(openScopeIds[i])
      }

      decorationIterator.moveToSuccessor()
    }
  }

  emitFold (nextHunk, decorationIterator) {
    this.emitCloseTag(this.getBuiltInScopeId(this.currentBuiltInClassNameFlags))
    this.currentBuiltInClassNameFlags = 0

    this.closeContainingScopes()
    this.scopeIdsToReopen.length = 0

    this.emitOpenTag(this.getBuiltInScopeId(FOLD))
    this.emitText(this.displayLayer.foldCharacter)
    this.emitCloseTag(this.getBuiltInScopeId(FOLD))

    this.bufferRow = nextHunk.oldEnd.row
    this.bufferColumn = nextHunk.oldEnd.column

    this.scopeIdsToReopen = decorationIterator.seek(Point(this.bufferRow, this.bufferColumn))

    this.bufferLine = this.displayLayer.buffer.lineForRow(this.bufferRow)
    this.trailingWhitespaceStartColumn = this.displayLayer.findTrailingWhitespaceStartColumn(this.bufferLine)
  }

  emitSoftWrap (nextHunk) {
    this.emitCloseTag(this.getBuiltInScopeId(this.currentBuiltInClassNameFlags))
    this.currentBuiltInClassNameFlags = 0
    this.closeContainingScopes()
    this.emitNewline()
    this.emitIndentWhitespace(nextHunk.newEnd.column)
  }

  emitLineEnding () {
    this.emitCloseTag(this.getBuiltInScopeId(this.currentBuiltInClassNameFlags))

    let lineEnding = this.displayLayer.buffer.lineEndingForRow(this.bufferRow)
    const eolInvisible = this.displayLayer.eolInvisibles[lineEnding]
    if (eolInvisible) {
      let eolFlags = INVISIBLE_CHARACTER | LINE_ENDING
      if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) eolFlags |= INDENT_GUIDE
      this.emitOpenTag(this.getBuiltInScopeId(eolFlags))
      this.emitText(eolInvisible, false)
      this.emitCloseTag(this.getBuiltInScopeId(eolFlags))
    }

    if (this.bufferLine.length === 0 && this.displayLayer.showIndentGuides) {
      let whitespaceLength = this.displayLayer.leadingWhitespaceLengthForSurroundingLines(this.bufferRow)
      this.emitIndentWhitespace(whitespaceLength)
    }

    this.closeContainingScopes()

    // Ensure empty lines have at least one empty token to make it easier on
    // the caller
    if (this.currentScreenLineTags.length === 0) this.currentScreenLineTags.push(0)
    this.emitNewline()
    this.bufferRow++
    this.bufferColumn = 0
  }

  emitNewline () {
    const screenLine = {
      id: nextScreenLineId++,
      lineText: this.currentScreenLineText,
      tags: this.currentScreenLineTags
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
            this.emitCloseTag(this.getBuiltInScopeId(INDENT_GUIDE))
          }

          this.emitOpenTag(this.getBuiltInScopeId(INDENT_GUIDE))
          openedIndentGuide = true
        }
        this.emitText(' ', false)
      }

      if (openedIndentGuide) this.emitCloseTag(this.getBuiltInScopeId(INDENT_GUIDE))
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
      this.currentScreenLineTags.push(this.currentTokenLength)
      this.currentTokenLength = 0
    }
  }

  emitEmptyTokenIfNeeded () {
    const lastTag = this.currentScreenLineTags[this.currentScreenLineTags.length - 1]
    if (this.displayLayer.isOpenTag(lastTag)) {
      this.currentScreenLineTags.push(0)
    }
  }

  emitCloseTag (scopeId) {
    this.emitTokenBoundary()

    if (scopeId === 0) return

    for (let i = this.scopeIdsToReopen.length - 1; i >= 0; i--) {
      if (this.scopeIdsToReopen[i] === scopeId) {
        this.scopeIdsToReopen.splice(i, 1)
        return
      }
    }

    this.emitEmptyTokenIfNeeded()

    var containingScopeId
    while ((containingScopeId = this.containingScopeIds.pop())) {
      this.currentScreenLineTags.push(this.displayLayer.closeTagForScopeId(containingScopeId))
      if (containingScopeId === scopeId) {
        return
      } else {
        this.scopeIdsToReopen.unshift(containingScopeId)
      }
    }
  }

  emitOpenTag (scopeId, reopenTags = true) {
    if (reopenTags) this.reopenTags()
    this.emitTokenBoundary()
    if (scopeId > 0) {
      this.containingScopeIds.push(scopeId)
      this.currentScreenLineTags.push(this.displayLayer.openTagForScopeId(scopeId))
    }
  }

  closeContainingScopes () {
    if (this.containingScopeIds.length > 0) this.emitEmptyTokenIfNeeded()

    for (let i = this.containingScopeIds.length - 1; i >= 0; i--) {
      const containingScopeId = this.containingScopeIds[i]
      this.currentScreenLineTags.push(this.displayLayer.closeTagForScopeId(containingScopeId))
      this.scopeIdsToReopen.unshift(containingScopeId)
    }
    this.containingScopeIds.length = 0
  }

  reopenTags () {
    for (let i = 0, n = this.scopeIdsToReopen.length; i < n; i++) {
      const scopeIdToReopen = this.scopeIdsToReopen[i]
      this.containingScopeIds.push(scopeIdToReopen)
      this.currentScreenLineTags.push(this.displayLayer.openTagForScopeId(scopeIdToReopen))
    }
    this.scopeIdsToReopen.length = 0
  }

  pushScreenLine (screenLine) {
    if (this.requestedStartScreenRow <= this.screenRow && this.screenRow < this.requestedEndScreenRow) {
      this.screenLines.push(screenLine)
    }
  }

  compareBufferPosition (position) {
    const rowComparison = this.bufferRow - position.row
    return rowComparison === 0 ? (this.bufferColumn - position.column) : rowComparison
  }
}
