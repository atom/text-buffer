const Patch = require('atom-patch/build/Release/atom_patch')
const {Emitter} = require('event-kit')
const Point = require('./point')
const Range = require('./range')
const EmptyDecorationLayer = require('./empty-decoration-layer')
const {traverse, traversal, compare, max, isEqual} = require('./point-helpers')
// const {normalizePatchChanges} = require('./helpers')

const HARD_TAB = 1 << 0
const LEADING_WHITESPACE = 1 << 2
const TRAILING_WHITESPACE = 1 << 3
const INVISIBLE_CHARACTER = 1 << 4
const INDENT_GUIDE = 1 << 5
const LINE_ENDING = 1 << 6
const FOLD = 1 << 7

const basicTagCache = new Map()

module.exports =
class DisplayLayer {
  constructor (id, buffer, params = {}) {
    this.id = id
    this.buffer = buffer
    this.foldIdCounter = 1
    this.foldsMarkerLayer = params.foldsMarkerLayer || buffer.addMarkerLayer({
      maintainHistory: false,
      persistent: true,
      destroyInvalidatedMarkers: true
    })
    this.spatialIndex = new Patch({mergeAdjacentHunks: false})
    this.screenLineLengths = []
    this.tagsByCode = new Map()
    this.codesByTag = new Map()
    this.nextOpenTagCode = -1
    this.textDecorationLayer = new EmptyDecorationLayer()
    this.emitter = new Emitter()

    this.invisibles = {}
    this.tabLength = 4
    this.softWrapColumn = Infinity
    this.softWrapHangingIndent = 0
    this.showIndentGuides = false
    this.ratioForCharacter = () => 1
    this.isWrapBoundary = isWordStart
    this.foldCharacter = '⋯'
    this.atomicSoftTabs = true
    this.reset(params)
  }

  reset (params) {
    if (params.hasOwnProperty('tabLength')) this.tabLength = params.tabLength
    if (params.hasOwnProperty('invisibles')) this.invisibles = params.invisibles
    if (params.hasOwnProperty('showIndentGuides')) this.showIndentGuides = params.showIndentGuides
    if (params.hasOwnProperty('softWrapColumn')) this.softWrapColumn = params.softWrapColumn
    if (params.hasOwnProperty('softWrapHangingIndent')) this.softWrapHangingIndent = params.softWrapHangingIndent
    if (params.hasOwnProperty('ratioForCharacter')) this.ratioForCharacter = params.ratioForCharacter
    if (params.hasOwnProperty('isWrapBoundary')) this.isWrapBoundary = params.isWrapBoundary
    if (params.hasOwnProperty('foldCharacter')) this.foldCharacter = params.foldCharacter
    if (params.hasOwnProperty('atomicSoftTabs')) this.atomicSoftTabs = params.atomicSoftTabs

    this.eolInvisibles = {
      '\r': this.invisibles.cr,
      '\n': this.invisibles.eol,
      '\r\n': this.invisibles.cr + this.invisibles.eol
    }

    this.emitter.emit('did-reset')

    this.updateSpatialIndex(0, 0, this.buffer.getLineCount())
  }

  copy () {
    const copyId = this.buffer.nextDisplayLayerId++
    const copy = new DisplayLayer(copyId, this.buffer, {
      foldsMarkerLayer: this.foldsMarkerLayer.copy(),
      invisibles: this.invisibles,
      tabLength: this.tabLength,
      softWrapColumn: this.softWrapColumn,
      softWrapHangingIndent: this.softWrapHangingIndent,
      showIndentGuides: this.showIndentGuides,
      ratioForCharacter: this.ratioForCharacter,
      isWrapBoundary: this.isWrapBoundary,
      foldCharacter: this.foldCharacter,
      atomicSoftTabs: this.atomicSoftTabs
    })
    this.buffer.displayLayers[copyId] = copy
    return copy
  }

  foldBufferRange (bufferRange) {
    bufferRange = Range.fromObject(bufferRange)
    const containingFoldMarkers = this.foldsMarkerLayer.findMarkers({containsRange: bufferRange})
    const foldId = this.foldsMarkerLayer.markRange(bufferRange).id
    if (containingFoldMarkers.length === 0) {
      const foldStartRow = bufferRange.start.row
      const foldEndRow = bufferRange.end.row + 1
      this.updateSpatialIndex(foldStartRow, foldEndRow, foldEndRow)
    }
    return foldId
  }

  destroyFold (foldId) {
    const foldMarker = this.foldsMarkerLayer.getMarker(foldId)
    if (foldMarker) {
      this.destroyFoldMarkers([foldMarker])
    }
  }

  destroyAllFolds () {
    return this.destroyFoldMarkers(this.foldsMarkerLayer.getMarkers())
  }

  destroyFoldsIntersectingBufferRange (bufferRange) {
    return this.destroyFoldMarkers(
      this.foldsMarkerLayer.findMarkers({
        intersectsRange: this.buffer.clipRange(bufferRange)
      })
    )
  }

  destroyFoldMarkers (foldMarkers) {
    const foldedRanges = []
    if (foldMarkers.length === 0) return foldedRanges

    const combinedRangeStart = foldMarkers[0].getStartPosition()
    let combinedRangeEnd = combinedRangeStart
    for (const foldMarker of foldMarkers) {
      const foldedRange = foldMarker.getRange()
      foldedRanges.push(foldedRange)
      combinedRangeEnd = max(combinedRangeEnd, foldedRange.end)
      foldMarker.destroy()
    }

    this.updateSpatialIndex(combinedRangeStart.row, combinedRangeEnd.row, combinedRangeEnd.row)
    return foldedRanges
  }

  foldsIntersectingBufferRange (bufferRange) {
    return this.foldsMarkerLayer.findMarkers({
      intersectsRange: this.buffer.clipRange(bufferRange)
    }).map((marker) => marker.id)
  }

  translateBufferPosition (bufferPosition, options) {
    if (!options || options.clip) {
      bufferPosition = this.buffer.clipPosition(bufferPosition)
    }
    let screenPosition
    let hunk = this.spatialIndex.hunkForOldPosition(bufferPosition)
    if (hunk) {
      if (compare(bufferPosition, hunk.oldEnd) < 0) {
        if (compare(hunk.oldStart, bufferPosition) === 0) {
          return Point.fromObject(hunk.newStart)
        } else {
          const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
          const tabCount = bufferPosition.column - hunk.oldStart.column
          const screenColumn = tabStopBeforeHunk + tabCount * this.tabLength
          return Point(hunk.newStart.row, screenColumn)
        }
      } else {
        screenPosition = traverse(hunk.newEnd, traversal(bufferPosition, hunk.oldEnd))
      }
    } else {
      screenPosition = Point.fromObject(bufferPosition)
    }

    if (this.atomicSoftTabs) {
      const clipDirection = options && options.clipDirection || 'closest'
      return this.clipAtomicSoftTabs(bufferPosition, screenPosition, clipDirection)
    } else {
      return screenPosition
    }
  }

  translateScreenPosition (screenPosition, options) {
    const clipDirection = options && options.clipDirection || 'closest'
    const skipSoftWrapIndentation = options && options.skipSoftWrapIndentation
    screenPosition = this.constrainScreenPosition(screenPosition, options)
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (compare(screenPosition, hunk.newEnd) < 0) {
        if (compare(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
          if (clipDirection === 'backward' && !skipSoftWrapIndentation ||
              clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
            return traverse(hunk.oldStart, Point(0, -1))
          } else {
            return Point.fromObject(hunk.oldStart)
          }
        } else { // Hard tab sequence
          if (compare(hunk.newStart, screenPosition) === 0) {
            return Point.fromObject(hunk.oldStart)
          }

          const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
          const targetColumn = screenPosition.column
          const tabStopBeforeTarget = targetColumn - targetColumn % this.tabLength
          const tabStopAfterTarget = tabStopBeforeTarget + this.tabLength

          let clippedTargetColumn
          if (targetColumn === tabStopBeforeTarget) {
            clippedTargetColumn = tabStopBeforeTarget
          } else {
            switch (clipDirection) {
              case 'backward':
                clippedTargetColumn = tabStopBeforeTarget
                break
              case 'forward':
                clippedTargetColumn = tabStopAfterTarget
                break
              case 'closest':
                clippedTargetColumn =
                  (targetColumn - tabStopBeforeTarget > tabStopAfterTarget - targetColumn)
                    ? tabStopAfterTarget
                    : tabStopBeforeTarget
                break
            }
          }

          return Point(
            hunk.oldStart.row,
            hunk.oldStart.column + (clippedTargetColumn - tabStopBeforeHunk) / this.tabLength
          )
        }
      } else {
        return traverse(hunk.oldEnd, traversal(screenPosition, hunk.newEnd))
      }
    } else {
      return Point.fromObject(screenPosition)
    }
  }

  clipScreenPosition (screenPosition, options) {
    const clipDirection = options && options.clipDirection || 'closest'
    const skipSoftWrapIndentation = options && options.skipSoftWrapIndentation
    screenPosition = this.constrainScreenPosition(screenPosition, options)
    let bufferPosition
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (compare(hunk.oldStart, hunk.oldEnd) === 0) {
        // hunk is a soft wrap

        if (clipDirection === 'backward' && !skipSoftWrapIndentation ||
            clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
          return traverse(hunk.newStart, Point(0, -1))
        } else {
          return Point.fromObject(hunk.newEnd)
        }
      } else if (compare(hunk.newStart, screenPosition) < 0 && compare(screenPosition, hunk.newEnd) < 0) {
        // clipped screen position is inside a hard tab

        const column = screenPosition.column
        const tabStopBeforeColumn = column - column % this.tabLength
        const tabStopAfterColumn = tabStopBeforeColumn + this.tabLength

        let clippedColumn
        if (column === tabStopBeforeColumn) {
          clippedColumn = tabStopBeforeColumn
        } else {
          switch (options && options.clipDirection) {
            case 'backward':
              clippedColumn = Math.max(tabStopBeforeColumn, hunk.newStart.column)
              break
            case 'forward':
              clippedColumn = tabStopAfterColumn
              break
            default:
              clippedColumn =
                (column - tabStopBeforeColumn > tabStopAfterColumn - column)
                  ? tabStopAfterColumn
                  : Math.max(tabStopBeforeColumn, hunk.newStart.column)
              break
          }
        }
        return Point(hunk.newStart.row, clippedColumn)
      } else if (compare(screenPosition, hunk.newEnd) > 0) {
        // clipped screen position follows a hunk; compute relative position
        bufferPosition = traverse(hunk.oldEnd, traversal(screenPosition, hunk.newEnd))
      } else {
        // clipped screen position is at the start of the hunk
        bufferPosition = hunk.oldStart
      }
    } else {
      // No hunks proceed this screen position
      bufferPosition = Point.fromObject(screenPosition)
    }

    if (this.atomicSoftTabs) {
      return this.clipAtomicSoftTabs(bufferPosition, Point.fromObject(screenPosition), clipDirection)
    } else {
      return Point.fromObject(screenPosition)
    }
  }

  constrainScreenPosition (screenPosition, options) {
    screenPosition = Point.fromObject(screenPosition)
    let {row, column} = screenPosition

    if (row < 0) {
      return new Point(0, 0)
    }

    const maxRow = this.screenLineLengths.length - 1
    if (row > maxRow) {
      return new Point(maxRow, 0)
    }

    if (column < 0) {
      return new Point(row, 0)
    }

    const maxColumn = this.screenLineLengths[row]
    if (column > maxColumn) {
      if (options && options.clipDirection === 'forward' && row < maxRow) {
        return new Point(row + 1, 0)
      } else {
        return new Point(row, maxColumn)
      }
    }

    return screenPosition
  }

  clipAtomicSoftTabs (bufferPosition, screenPosition, clipDirection) {
    const bufferLine = this.buffer.lineForRow(bufferPosition.row)
    let bufferColumn = bufferPosition.column
    let screenColumn = screenPosition.column
    let inLeadingWhitespace = true

    while (bufferColumn > 0) {
      const character = bufferLine[bufferColumn]
      if (character === ' ') {
        bufferColumn--
        screenColumn--
      } else {
        inLeadingWhitespace = false
        break
      }
    }

    if (inLeadingWhitespace && screenColumn === 0) {
      const previousTabStop = screenPosition.column - (screenPosition.column % this.tabLength)
      const nextTabStop = previousTabStop + this.tabLength

      // If there is a non-whitespace character before the next tab stop,
      // don't this whitespace as a soft tab
      for (let bufferColumn = bufferPosition.column; bufferColumn < nextTabStop; bufferColumn++) {
        if (bufferLine[bufferColumn] !== ' ') {
          return screenPosition
        }
      }

      if (clipDirection === 'closest') {
        if (screenPosition.column - previousTabStop > this.tabLength / 2) {
          return Point(screenPosition.row, nextTabStop)
        } else {
          return Point(screenPosition.row, previousTabStop)
        }
      } else if (clipDirection === 'backward') {
        return Point(screenPosition.row, previousTabStop)
      } else if (clipDirection === 'forward') {
        return Point(screenPosition.row, nextTabStop)
      }
    } else {
      return screenPosition
    }
  }

  getText () {
    return this.getScreenLines().map((line) => line.lineText).join('\n')
  }

  getLastScreenRow () {
    return this.screenLineLengths.length - 1
  }

  getScreenLineCount () {
    return this.screenLineLengths.length
  }

  getScreenLines (screenStartRow = 0, screenEndRow = this.getLastScreenRow() + 1) {
    const screenStart = Point(screenStartRow, 0)
    const screenEnd = Point(screenEndRow, 0)
    let screenLines = []
    let screenRow = screenStartRow
    let {row: bufferRow} = this.translateScreenPosition(screenStart)

    let hunkIndex = 0
    const hunks = this.spatialIndex.getHunksInNewRange(screenStart, screenEnd)
    while (screenRow < screenEndRow) {
      let screenLine = ''
      let tagCodes = []
      let currentTokenLength = 0
      let currentTokenFlags = 0
      let screenColumn = 0
      let bufferLine = this.buffer.lineForRow(bufferRow)
      let lineEnding = this.buffer.lineEndingForRow(bufferRow)
      let bufferColumn = 0
      let trailingWhitespaceStartColumn = this.findTrailingWhitespaceStartColumn(bufferLine)
      let inLeadingWhitespace = true
      let inTrailingWhitespace = false

      // If the buffer line is empty, indent guides may extend beyond the line-ending
      // invisible, requiring this separate code path.
      if (bufferLine.length === 0) {
        const eolInvisible = this.eolInvisibles[lineEnding]
        if (eolInvisible) {
          screenLine += eolInvisible
          currentTokenFlags |= INVISIBLE_CHARACTER | LINE_ENDING
          if (this.showIndentGuides) currentTokenFlags |= INDENT_GUIDE
          this.pushOpenTag(tagCodes, 0, this.getBasicTag(currentTokenFlags))
          this.pushCloseTag(tagCodes, eolInvisible.length, this.getBasicTag(currentTokenFlags))
          screenColumn += eolInvisible.length
        }

        if (this.showIndentGuides) {
          currentTokenFlags = 0
          currentTokenLength = 0
          let whitespaceLength = this.leadingWhitespaceLengthForSurroundingLines(bufferRow)
          while (screenColumn < whitespaceLength) {
            if (screenColumn % this.tabLength === 0) {
              if (currentTokenLength > 0) {
                tagCodes.push(currentTokenLength)
              }

              if (currentTokenFlags !== 0) {
                tagCodes.push(this.codeForCloseTag(this.getBasicTag(currentTokenFlags)))
              }

              currentTokenLength = 0
              currentTokenFlags = INDENT_GUIDE
              this.pushOpenTag(tagCodes, 0, this.getBasicTag(currentTokenFlags))
            }
            screenLine += ' '
            screenColumn++
            currentTokenLength++
          }
          if (currentTokenLength > 0) {
            this.pushCloseTag(tagCodes, currentTokenLength, this.getBasicTag(currentTokenFlags))
          }
        }

        // Ensure empty lines have at least one empty token to make it easier on
        // the caller
        if (tagCodes.length === 0) tagCodes.push(0)
      } else {
        while (bufferColumn <= bufferLine.length) {
          let forceTokenBoundary = false
          const previousTokenFlags = currentTokenFlags
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
          currentTokenFlags = 0
          if (nextCharacter === ' ' || nextCharacter === '\t') {
            const showIndentGuides = this.showIndentGuides && (inLeadingWhitespace || trailingWhitespaceStartColumn === 0)
            if (inLeadingWhitespace) currentTokenFlags |= LEADING_WHITESPACE
            if (inTrailingWhitespace) currentTokenFlags |= TRAILING_WHITESPACE

            if (nextCharacter === ' ') {
              if ((inLeadingWhitespace || inTrailingWhitespace) && this.invisibles.space) {
                currentTokenFlags |= INVISIBLE_CHARACTER
              }

              if (showIndentGuides) {
                currentTokenFlags |= INDENT_GUIDE
                if (screenColumn % this.tabLength === 0) forceTokenBoundary = true
              }
            } else { // nextCharacter === \t
              currentTokenFlags |= HARD_TAB
              if (this.invisibles.tab) currentTokenFlags |= INVISIBLE_CHARACTER
              if (showIndentGuides && screenColumn % this.tabLength === 0) {
                currentTokenFlags |= INDENT_GUIDE
              }

              forceTokenBoundary = true
            }
          } else {
            inLeadingWhitespace = false
          }

          if (previousTokenFlags > 0 &&
              (currentTokenFlags !== previousTokenFlags || forceTokenBoundary)) {
            this.pushCloseTag(tagCodes, currentTokenLength, this.getBasicTag(previousTokenFlags))
            currentTokenLength = 0
          }

          // Handle folds or soft wraps at the current position.
          {
            const nextHunk = hunks[hunkIndex]
            if (nextHunk && nextHunk.oldStart.row === bufferRow && nextHunk.oldStart.column === bufferColumn) {
              // Does a fold hunk start here? Jump to the end of the fold and
              // continue to the next iteration of the loop.
              if (nextHunk.newText === this.foldCharacter) {
                if (previousTokenFlags > 0) {
                  this.pushCloseTag(tagCodes, currentTokenLength, this.getBasicTag(previousTokenFlags))
                } else if (currentTokenLength > 0) {
                  tagCodes.push(currentTokenLength)
                }

                screenLine += this.foldCharacter
                screenColumn++
                this.pushOpenTag(tagCodes, 0, this.getBasicTag(FOLD))
                currentTokenLength = 1
                currentTokenFlags = FOLD
                bufferRow = nextHunk.oldEnd.row
                bufferColumn = nextHunk.oldEnd.column
                bufferLine = this.buffer.lineForRow(bufferRow)
                inTrailingWhitespace = false
                trailingWhitespaceStartColumn = this.findTrailingWhitespaceStartColumn(bufferLine)
                hunkIndex++
                continue
              }

              // If the oldExtent of the hunk is zero, this is a soft line break.
              if (isEqual(nextHunk.oldStart, nextHunk.oldEnd)) {
                if (currentTokenFlags > 0) {
                  this.pushCloseTag(tagCodes, currentTokenLength, this.getBasicTag(currentTokenFlags))
                } else if (currentTokenLength > 0) {
                  tagCodes.push(currentTokenLength)
                }

                screenLines.push({lineText: screenLine, tagCodes})
                screenRow++

                // Make indent of soft-wrapped segment match the indent of the
                // original line, rendering indent guides if necessary.
                const indentLength = nextHunk.newEnd.column
                screenLine = ' '.repeat(indentLength)
                tagCodes = []
                if (this.showIndentGuides && indentLength > 0) {
                  screenColumn = 0
                  currentTokenLength = 0
                  while (screenColumn < indentLength) {
                    if (screenColumn % this.tabLength === 0) {
                      if (currentTokenLength > 0) {
                        tagCodes.push(currentTokenLength)
                        tagCodes.push(this.codeForCloseTag(this.getBasicTag(INDENT_GUIDE)))
                        currentTokenLength = 0
                      }
                      this.pushOpenTag(tagCodes, 0, this.getBasicTag(INDENT_GUIDE))
                    }
                    screenColumn++
                    currentTokenLength++
                  }
                  if (currentTokenLength > 0) {
                    tagCodes.push(currentTokenLength)
                    tagCodes.push(this.codeForCloseTag(this.getBasicTag(INDENT_GUIDE)))
                    currentTokenLength = 0
                  }
                } else {
                  screenColumn = indentLength
                  currentTokenLength = indentLength
                }
              }
              hunkIndex++
            }
          }

          // We loop up to the end of the buffer line in case a fold starts there,
          // but at this point we haven't found a fold, so we can stop if we have
          // reached the end of the line. We need to close any open tags and
          // append the line ending invisible if it is enabled, then break the
          // loop to proceed to the next line.
          if (bufferColumn === bufferLine.length) {
            if (currentTokenLength > 0) {
              if (previousTokenFlags > 0) {
                this.pushCloseTag(tagCodes, currentTokenLength, this.getBasicTag(previousTokenFlags))
              } else if (currentTokenLength > 0) {
                tagCodes.push(currentTokenLength)
              }
              currentTokenLength = 0
            }

            const eolInvisible = this.eolInvisibles[lineEnding]
            if (eolInvisible) {
              screenLine += eolInvisible
              const eolTag = this.getBasicTag(INVISIBLE_CHARACTER | LINE_ENDING)
              this.pushOpenTag(tagCodes, 0, eolTag)
              this.pushCloseTag(tagCodes, eolInvisible.length, eolTag)
            }

            break
          }

          // At this point we know we aren't at the end of the line, so we proceed
          // to process the next character.

          // If the current token's flags differ from the previous iteration or
          // we are forcing a token boundary (for example between two hard tabs),
          // push an open tag based on the new flags.
          if (currentTokenFlags > 0 &&
              currentTokenFlags !== previousTokenFlags || forceTokenBoundary) {
            this.pushOpenTag(tagCodes, currentTokenLength, this.getBasicTag(currentTokenFlags))
            currentTokenLength = 0
          }

          // Handle tabs and leading / trailing whitespace invisibles specially.
          // Otherwise just append the next character to the screen line.
          if (nextCharacter === '\t') {
            currentTokenLength = 0
            const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
            if (this.invisibles.tab) {
              screenLine += this.invisibles.tab
              screenLine += ' '.repeat(distanceToNextTabStop - 1)
            } else {
              screenLine += ' '.repeat(distanceToNextTabStop)
            }

            screenColumn += distanceToNextTabStop
            currentTokenLength += distanceToNextTabStop
          } else {
            if ((inLeadingWhitespace || inTrailingWhitespace) &&
                nextCharacter === ' ' && this.invisibles.space) {
              screenLine += this.invisibles.space
            } else {
              screenLine += nextCharacter
            }
            screenColumn++
            currentTokenLength++
          }
          bufferColumn++
        }
      }

      screenLines.push({lineText: screenLine, tagCodes})
      screenRow++
      bufferRow++
    }

    return screenLines
  }

  leadingWhitespaceLengthForSurroundingLines (startBufferRow) {
    let length = 0
    for (let bufferRow = startBufferRow - 1; bufferRow >= 0; bufferRow--) {
      const line = this.buffer.lineForRow(bufferRow)
      if (line.length > 0) {
        length = this.leadingWhitespaceLengthForNonEmptyLine(line)
        break
      }
    }

    const lineCount = this.buffer.getLineCount()
    for (let bufferRow = startBufferRow + 1; bufferRow < lineCount; bufferRow++) {
      const line = this.buffer.lineForRow(bufferRow)
      if (line.length > 0) {
        length = Math.max(length, this.leadingWhitespaceLengthForNonEmptyLine(line))
        break
      }
    }

    return length
  }

  leadingWhitespaceLengthForNonEmptyLine (line) {
    let length = 0
    for (let i = 0; i < line.length; i++) {
      const character = line[i]
      if (character === ' ') {
        length++
      } else if (character === '\t') {
        length += this.tabLength - (length % this.tabLength)
      } else {
        break
      }
    }
    return length
  }

  findTrailingWhitespaceStartColumn (lineText) {
    let column
    for (column = lineText.length; column >= 0; column--) {
      const previousCharacter = lineText[column - 1]
      if (previousCharacter !== ' ' && previousCharacter !== '\t') {
        break
      }
    }
    return column
  }

  pushCloseTag (tagCodes, currentTokenLength, closeTag) {
    if (currentTokenLength > 0) tagCodes.push(currentTokenLength)
    tagCodes.push(this.codeForCloseTag(closeTag))
  }

  pushOpenTag (tagCodes, currentTokenLength, openTag) {
    if (currentTokenLength > 0) tagCodes.push(currentTokenLength)
    tagCodes.push(this.codeForOpenTag(openTag))
  }

  tagForCode (tagCode) {
    if (this.isCloseTagCode(tagCode)) tagCode++
    return this.tagsByCode.get(tagCode)
  }

  codeForOpenTag (tag) {
    if (this.codesByTag.has(tag)) {
      return this.codesByTag.get(tag)
    } else {
      const tagCode = this.nextOpenTagCode
      this.codesByTag.set(tag, tagCode)
      this.tagsByCode.set(tagCode, tag)
      this.nextOpenTagCode -= 2
      return tagCode
    }
  }

  codeForCloseTag (tag) {
    return this.codeForOpenTag(tag) - 1
  }

  isOpenTagCode (tagCode) {
    return tagCode < 0 && tagCode % 2 === -1
  }

  isCloseTagCode (tagCode) {
    return tagCode < 0 && tagCode % 2 === 0
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

  bufferWillChange () {

  }

  bufferDidChange (change) {
    this.updateSpatialIndex(
      change.oldRange.start.row,
      change.oldRange.end.row + 1,
      change.newRange.end.row + 1
    )
  }

  emitDidChangeSyncEvent () {

  }

  updateSpatialIndex (startBufferRow, oldEndBufferRow, newEndBufferRow) {
    const originalOldEndBufferRow = oldEndBufferRow
    startBufferRow = this.findBoundaryPrecedingBufferRow(startBufferRow)
    oldEndBufferRow = this.findBoundaryFollowingBufferRow(oldEndBufferRow)
    newEndBufferRow += (oldEndBufferRow - originalOldEndBufferRow)

    const startScreenRow = this.translateBufferPosition({row: startBufferRow, column: 0}).row
    const oldEndScreenRow = this.translateBufferPosition({row: oldEndBufferRow, column: 0}, {clip: false}).row
    this.spatialIndex.spliceOld(
      {row: startBufferRow, column: 0},
      {row: oldEndBufferRow - startBufferRow, column: 0},
      {row: newEndBufferRow - startBufferRow, column: 0}
    )

    const folds = this.computeFoldsInBufferRowRange(startBufferRow, newEndBufferRow)

    const newScreenLineLengths = []
    let bufferRow = startBufferRow
    let screenRow = startScreenRow
    let bufferColumn = 0
    let screenColumn = 0

    while (bufferRow < newEndBufferRow) {
      let bufferLine = this.buffer.lineForRow(bufferRow)
      let bufferLineLength = bufferLine.length
      let tabSequenceLength = 0
      let tabSequenceStartScreenColumn = -1
      let screenLineWidth = 0
      let lastWrapBoundaryScreenColumn = 0
      let lastWrapBoundaryScreenLineWidth = 0
      let firstNonWhitespaceScreenColumn = -1

      while (bufferColumn <= bufferLineLength) {
        const foldEnd = folds[bufferRow] && folds[bufferRow][bufferColumn]
        const previousCharacter = bufferLine[bufferColumn - 1]
        const character = foldEnd ? this.foldCharacter : bufferLine[bufferColumn]

        // Terminate any pending tab sequence if we've reached a non-tab
        if (tabSequenceLength > 0 && character !== '\t') {
          this.spatialIndex.splice(
            Point(screenRow, tabSequenceStartScreenColumn),
            Point(0, tabSequenceLength),
            Point(0, screenColumn - tabSequenceStartScreenColumn)
          )
          tabSequenceLength = 0
          tabSequenceStartScreenColumn = -1
        }

        // Are we in leading whitespace? If yes, record the *end* of the leading
        // whitespace if we've reached a non whitespace character. If no, record
        // the current column if it is a viable soft wrap boundary.
        if (firstNonWhitespaceScreenColumn < 0) {
          if (character !== ' ' && character !== '\t') {
            firstNonWhitespaceScreenColumn = screenColumn
          }
        } else {
          if (this.isWrapBoundary(previousCharacter, character)) {
            lastWrapBoundaryScreenColumn = screenColumn
            lastWrapBoundaryScreenLineWidth = screenLineWidth
          }
        }

        // Determine the on-screen width of the character for soft-wrap calculations
        let characterWidth
        if (character === '\t') {
          const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
          characterWidth = this.ratioForCharacter(' ') * distanceToNextTabStop
        } else if (character) {
          characterWidth = this.ratioForCharacter(character)
        } else {
          characterWidth = 0
        }

        // Insert a soft line break if necessary
        if (screenLineWidth > 0 && characterWidth > 0 &&
            screenLineWidth + characterWidth > this.softWrapColumn) {
          let indentLength = (firstNonWhitespaceScreenColumn < this.softWrapColumn)
            ? Math.max(0, firstNonWhitespaceScreenColumn)
            : 0
          if (indentLength + this.softWrapHangingIndent < this.softWrapColumn) {
            indentLength += this.softWrapHangingIndent
          }

          const wrapColumn = lastWrapBoundaryScreenColumn || screenColumn
          const wrapWidth = lastWrapBoundaryScreenLineWidth || screenLineWidth
          this.spatialIndex.splice(
            Point(screenRow, wrapColumn),
            Point.ZERO,
            Point(1, indentLength)
          )
          newScreenLineLengths.push(wrapColumn)
          screenRow++
          screenColumn = indentLength + (screenColumn - wrapColumn)
          screenLineWidth = (indentLength * this.ratioForCharacter(' ')) + (screenLineWidth - wrapWidth)
          lastWrapBoundaryScreenColumn = 0
          lastWrapBoundaryScreenLineWidth = 0
        }

        screenLineWidth += characterWidth

        // If there is a fold at this position, splice it into the spatial index
        // and jump to the end of the fold.
        if (foldEnd) {
          this.spatialIndex.splice(
            {row: screenRow, column: screenColumn},
            traversal(foldEnd, {row: bufferRow, column: bufferColumn}),
            {row: 0, column: 1},
            this.foldCharacter
          )
          screenColumn++
          bufferRow = foldEnd.row
          bufferColumn = foldEnd.column
          bufferLine = this.buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
        } else {
          // If there is no fold at this position, check if we need to handle
          // a hard tab at this position and advance by a single buffer column.
          if (character === '\t') {
            if (tabSequenceLength === 0) {
              tabSequenceStartScreenColumn = screenColumn
            }
            tabSequenceLength++
            const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
            screenColumn += distanceToNextTabStop
          } else {
            screenColumn++
          }
          bufferColumn++
        }
      }

      newScreenLineLengths.push(screenColumn - 1)

      bufferRow++
      bufferColumn = 0

      screenRow++
      screenColumn = 0
    }

    this.screenLineLengths.splice(
      startScreenRow,
      oldEndScreenRow - startScreenRow,
      ...newScreenLineLengths
    )
  }

  findBoundaryPrecedingBufferRow (bufferRow) {
    while (true) {
      let screenPosition = this.translateBufferPosition(Point(bufferRow, 0))
      if (screenPosition.column === 0) {
        return bufferRow
      } else {
        let bufferPosition = this.translateScreenPosition(Point(screenPosition.row, 0))
        if (bufferPosition.column === 0) {
          return bufferPosition.row
        } else {
          bufferRow = bufferPosition.row
        }
      }
    }
  }

  findBoundaryFollowingBufferRow (bufferRow) {
    while (true) {
      let screenPosition = this.translateBufferPosition(Point(bufferRow, 0), {clip: false})
      if (screenPosition.column === 0) {
        return bufferRow
      } else {
        const endOfScreenRow = Point(
          screenPosition.row,
          this.screenLineLengths[screenPosition.row]
        )
        bufferRow = this.translateScreenPosition(endOfScreenRow).row + 1
      }
    }
  }

  // Returns a map describing fold starts and ends, structured as
  // fold start row -> fold start column -> fold end point
  computeFoldsInBufferRowRange (startBufferRow, endBufferRow) {
    const folds = {}
    const foldMarkers = this.foldsMarkerLayer.findMarkers({
      intersectsRowRange: [startBufferRow, endBufferRow - 1]
    })

    for (let i = 0; i < foldMarkers.length; i++) {
      const foldStart = foldMarkers[i].getStartPosition()
      let foldEnd = foldMarkers[i].getEndPosition()

      // Merge overlapping folds
      while (i < foldMarkers.length - 1) {
        const nextFoldMarker = foldMarkers[i + 1]
        if (compare(nextFoldMarker.getStartPosition(), foldEnd) < 0) {
          if (compare(foldEnd, nextFoldMarker.getEndPosition()) < 0) {
            foldEnd = nextFoldMarker.getEndPosition()
          }
          i++
        } else {
          break
        }
      }

      // Add non-empty folds to the returned result
      if (compare(foldStart, foldEnd) < 0) {
        if (!folds[foldStart.row]) folds[foldStart.row] = {}
        folds[foldStart.row][foldStart.column] = foldEnd
      }
    }

    return folds
  }
}


function isWordStart (previousCharacter, character) {
  return (previousCharacter === ' ' || previousCharacter === '\t') &&
    (character !== ' ' && character !== '\t')
}
