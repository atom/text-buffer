const Patch = require('atom-patch/build/Release/atom_patch')
const {Emitter} = require('event-kit')
const Point = require('./point')
const Range = require('./range')
const EmptyDecorationLayer = require('./empty-decoration-layer')
const {traverse, traversal, compare, max, isEqual} = require('./point-helpers')
// const {normalizePatchChanges} = require('./helpers')

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
    let hunk = this.spatialIndex.hunkForOldPosition(bufferPosition)
    if (hunk) {
      if (compare(bufferPosition, hunk.oldEnd) < 0) {
        if (compare(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
          if (options && options.clipDirection === 'forward') {
            return Point.fromObject(hunk.newEnd)
          } else {
            return Point.fromObject(hunk.newStart).traverse(Point(0, -1))
          }
        } else { // Hard tab sequence
          if (compare(hunk.oldStart, bufferPosition) === 0) {
            return Point.fromObject(hunk.newStart)
          } else {
            const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
            const tabCount = bufferPosition.column - hunk.oldStart.column
            const screenColumn = tabStopBeforeHunk + tabCount * this.tabLength
            return Point(hunk.newStart.row, screenColumn)
          }
        }
      } else {
        return traverse(hunk.newEnd, traversal(bufferPosition, hunk.oldEnd))
      }
    } else {
      return Point.fromObject(bufferPosition)
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
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (compare(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
        if (clipDirection === 'backward' && !skipSoftWrapIndentation ||
            clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
          return traverse(hunk.newStart, Point(0, -1))
        } else {
          return Point.fromObject(hunk.newEnd)
        }
      } else { // Hard tab
        if (compare(hunk.newStart, screenPosition) < 0 &&
            compare(screenPosition, hunk.newEnd) < 0) {
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
        }
      }
    }
    return Point.fromObject(screenPosition)
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

  getText () {
    return this.getScreenLines().map((line) => line.lineText).join('\n')
  }

  getLastScreenRow () {
    return this.screenLineLengths.length - 1
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
      let screenColumn = 0
      let bufferLine = this.buffer.lineForRow(bufferRow)
      let bufferColumn = 0

      while (bufferColumn <= bufferLine.length) {
        // Handle folds or soft wraps at the current position. The extra block
        // scope ensures we don't accidentally refer to nextHunk later in the
        // method.
        {
          const nextHunk = hunks[hunkIndex]
          if (nextHunk && nextHunk.oldStart.row === bufferRow && nextHunk.oldStart.column === bufferColumn) {
            // Does a fold hunk start here? Jump to the end of the fold and
            // continue to the next iteration of the loop.
            if (nextHunk.newText === this.foldCharacter) {
              screenLine += this.foldCharacter
              screenColumn++
              bufferRow = nextHunk.oldEnd.row
              bufferColumn = nextHunk.oldEnd.column
              bufferLine = this.buffer.lineForRow(bufferRow)
              hunkIndex++
              continue
            }

            // If the oldExtent of the hunk is zero, this is a soft line break.
            if (isEqual(nextHunk.oldStart, nextHunk.oldEnd)) {
              screenLines.push({lineText: screenLine})
              screenRow++
              screenColumn = nextHunk.newEnd.column
              screenLine = ' '.repeat(screenColumn)
            }
            hunkIndex++
          }
        }

        // We loop up to the end of the buffer line in case a fold starts there,
        // but at this point we haven't found a fold, so we can stop if we have
        // reached the end of the line.
        if (bufferColumn === bufferLine.length) break

        const character = bufferLine[bufferColumn]
        if (character === '\t') {
          const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
          screenLine += ' '.repeat(distanceToNextTabStop)
          screenColumn += distanceToNextTabStop
        } else {
          screenLine += character
          screenColumn++
        }
        bufferColumn++
      }

      screenLines.push({lineText: screenLine})
      screenRow++
      bufferRow++
    }

    return screenLines
  }

  updateSpatialIndex (startBufferRow, oldEndBufferRow, newEndBufferRow) {
    startBufferRow = this.findBoundaryPrecedingBufferRow(startBufferRow)
    oldEndBufferRow = this.findBoundaryFollowingBufferRow(oldEndBufferRow)
    // newEndBufferRow += (oldEndBufferRow - startBufferRow) - deletedRowExtent

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
