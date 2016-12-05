const Patch = require('atom-patch/build/Release/atom_patch')
const {Emitter} = require('event-kit')
const Point = require('./point')
const Range = require('./range')
const EmptyDecorationLayer = require('./empty-decoration-layer')
const DisplayMarkerLayer = require('./display-marker-layer')
const {traverse, traversal, compare, max, isEqual} = require('./point-helpers')
const isCharacterPair = require('./is-character-pair')
const ScreenLineBuilder = require('./screen-line-builder')
const {spliceArray} = require('./helpers')

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
    this.screenLineBuilder = new ScreenLineBuilder(this)
    this.spatialIndex = new Patch({mergeAdjacentHunks: false})
    this.rightmostScreenPosition = Point(0, 0)
    this.screenLineLengths = [0]
    this.cachedScreenLines = []
    this.tagsByCode = new Map()
    this.codesByTag = new Map()
    this.nextOpenTagCode = -1
    this.textDecorationLayer = new EmptyDecorationLayer()
    this.displayMarkerLayersById = new Map()
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

  static deserialize (buffer, params) {
    const foldsMarkerLayer = buffer.getMarkerLayer(params.foldsMarkerLayerId)
    return new DisplayLayer(params.id, buffer, {foldsMarkerLayer})
  }

  serialize () {
    return {
      id: this.id,
      foldsMarkerLayerId: this.foldsMarkerLayer.id
    }
  }

  reset (params) {
    if (params.hasOwnProperty('tabLength')) this.tabLength = params.tabLength
    if (params.hasOwnProperty('invisibles')) this.invisibles = params.invisibles
    if (params.hasOwnProperty('showIndentGuides')) this.showIndentGuides = params.showIndentGuides
    if (params.hasOwnProperty('softWrapColumn')) {
      if (params.softWrapColumn != null) {
        this.softWrapColumn = Math.max(params.softWrapColumn, 1)
      } else {
        this.softWrapColumn = Infinity
      }
    }
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

    this.updateSpatialIndex(0, this.buffer.getLineCount(), this.buffer.getLineCount())
    this.spatialIndex.rebalance()
    this.emitter.emit('did-reset')
    this.notifyObserversIfMarkerScreenPositionsChanged()
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

  destroy () {
    this.spatialIndex = null
    this.screenLineLengths = null
    this.foldsMarkerLayer.destroy()
    this.displayMarkerLayersById.forEach((layer) => layer.destroy())
    if (this.decorationLayerDisposable) this.decorationLayerDisposable.dispose()
    delete this.buffer.displayLayers[this.id]
  }

  doBackgroundWork () {
  }

  getTextDecorationLayer () {
    return this.textDecorationLayer
  }

  setTextDecorationLayer (textDecorationLayer) {
    this.textDecorationLayer = textDecorationLayer
    if (typeof textDecorationLayer.onDidInvalidateRange === 'function') {
      this.decorationLayerDisposable = textDecorationLayer.onDidInvalidateRange((bufferRange) => {
        const screenRange = this.translateBufferRange(bufferRange)
        const extent = screenRange.getExtent()
        this.cachedScreenLines.splice(screenRange.start, extent.row, new Array(extent.row))
        this.emitDidChangeSyncEvent([{
          start: screenRange.start,
          oldExtent: extent,
          newExtent: extent
        }])
      })
    }
  }

  addMarkerLayer (options) {
    const markerLayer = new DisplayMarkerLayer(this, this.buffer.addMarkerLayer(options), true)
    this.displayMarkerLayersById.set(markerLayer.id, markerLayer)
    return markerLayer
  }

  getMarkerLayer (id) {
    if (this.displayMarkerLayersById.has(id)) {
      return this.displayMarkerLayersById.get(id)
    } else {
      const bufferMarkerLayer = this.buffer.getMarkerLayer(id)
      if (bufferMarkerLayer) {
        const displayMarkerLayer = new DisplayMarkerLayer(this, bufferMarkerLayer, false)
        this.displayMarkerLayersById.set(id, displayMarkerLayer)
        return displayMarkerLayer
      }
    }
  }

  didDestroyMarkerLayer (id) {
    this.displayMarkerLayersById.delete(id)
  }

  onDidChangeSync (callback) {
    return this.emitter.on('did-change-sync', callback)
  }

  onDidReset (callback) {
    return this.emitter.on('did-reset', callback)
  }

  foldBufferRange (bufferRange) {
    bufferRange = Range.fromObject(bufferRange)
    const containingFoldMarkers = this.foldsMarkerLayer.findMarkers({containsRange: bufferRange})
    const foldId = this.foldsMarkerLayer.markRange(bufferRange).id
    if (containingFoldMarkers.length === 0) {
      const foldStartRow = bufferRange.start.row
      const foldEndRow = bufferRange.end.row + 1
      this.emitDidChangeSyncEvent([
        this.updateSpatialIndex(foldStartRow, foldEndRow, foldEndRow)
      ])
      this.notifyObserversIfMarkerScreenPositionsChanged()
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

    this.emitDidChangeSyncEvent([this.updateSpatialIndex(
      combinedRangeStart.row,
      combinedRangeEnd.row + 1,
      combinedRangeEnd.row + 1
    )])
    this.notifyObserversIfMarkerScreenPositionsChanged()

    return foldedRanges
  }

  foldsIntersectingBufferRange (bufferRange) {
    return this.foldsMarkerLayer.findMarkers({
      intersectsRange: this.buffer.clipRange(bufferRange)
    }).map((marker) => marker.id)
  }

  translateBufferPosition (bufferPosition, options) {
    bufferPosition = this.buffer.clipPosition(bufferPosition)
    const clipDirection = options && options.clipDirection || 'closest'
    const screenPosition = this.translateBufferPositionWithoutBufferClipping(bufferPosition, clipDirection)
    const columnDelta = this.getClipColumnDelta(bufferPosition, clipDirection)
    if (columnDelta !== 0) {
      return Point(screenPosition.row, screenPosition.column + columnDelta)
    } else {
      return Point.fromObject(screenPosition)
    }
  }

  translateBufferPositionWithoutBufferClipping (bufferPosition, clipDirection) {
    let hunk = this.spatialIndex.hunkForOldPosition(bufferPosition)
    if (hunk) {
      if (compare(bufferPosition, hunk.oldEnd) < 0) {
        if (compare(hunk.oldStart, bufferPosition) === 0) {
          return hunk.newStart
        } else if (hunk.newText === this.foldCharacter) {
          if (clipDirection === 'backward') {
            return hunk.newStart
          } else if (clipDirection === 'forward') {
            return hunk.newEnd
          } else {
            const distanceFromFoldStart = traversal(bufferPosition, hunk.oldStart)
            const distanceToFoldEnd = traversal(hunk.oldEnd, bufferPosition)
            if (compare(distanceFromFoldStart, distanceToFoldEnd) <= 0) {
              return hunk.newStart
            } else {
              return hunk.newEnd
            }
          }
        } else {
          const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
          const tabCount = bufferPosition.column - hunk.oldStart.column
          const screenColumn = tabStopBeforeHunk + tabCount * this.tabLength
          return Point(hunk.newStart.row, screenColumn)
        }
      } else {
        return traverse(hunk.newEnd, traversal(bufferPosition, hunk.oldEnd))
      }
    } else {
      return bufferPosition
    }
  }

  translateBufferRange (bufferRange, options) {
    bufferRange = Range.fromObject(bufferRange)
    return Range(
      this.translateBufferPosition(bufferRange.start, options),
      this.translateBufferPosition(bufferRange.end, options)
    )
  }

  translateScreenPosition (screenPosition, options) {
    screenPosition = Point.fromObject(screenPosition)
    const clipDirection = options && options.clipDirection || 'closest'
    const skipSoftWrapIndentation = options && options.skipSoftWrapIndentation
    const bufferPosition = this.translateScreenPositionWithoutBufferClipping(screenPosition, clipDirection, skipSoftWrapIndentation)
    const columnDelta = this.getClipColumnDelta(bufferPosition, clipDirection)
    if (columnDelta !== 0) {
      return Point(bufferPosition.row, bufferPosition.column + columnDelta)
    } else {
      return Point.fromObject(bufferPosition)
    }
  }

  translateScreenPositionWithoutBufferClipping (screenPosition, clipDirection, skipSoftWrapIndentation) {
    screenPosition = this.constrainScreenPosition(screenPosition, clipDirection)
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (compare(screenPosition, hunk.newEnd) < 0) {
        if (compare(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
          if (clipDirection === 'backward' && !skipSoftWrapIndentation ||
              clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
            return traverse(hunk.oldStart, Point(0, -1))
          } else {
            return hunk.oldStart
          }
        } else { // Hard tab sequence
          if (compare(hunk.newStart, screenPosition) === 0) {
            return hunk.oldStart
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
      return screenPosition
    }
  }

  translateScreenRange (screenRange, options) {
    screenRange = Range.fromObject(screenRange)
    return Range(
      this.translateScreenPosition(screenRange.start, options),
      this.translateScreenPosition(screenRange.end, options)
    )
  }

  clipScreenPosition (screenPosition, options) {
    const clipDirection = options && options.clipDirection || 'closest'
    const skipSoftWrapIndentation = options && options.skipSoftWrapIndentation
    screenPosition = this.constrainScreenPosition(screenPosition, clipDirection)
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

    const columnDelta = this.getClipColumnDelta(bufferPosition, clipDirection)
    if (columnDelta !== 0) {
      return Point(screenPosition.row, screenPosition.column + columnDelta)
    } else {
      return screenPosition
    }
  }

  constrainScreenPosition (screenPosition, clipDirection) {
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
      if (clipDirection === 'forward' && row < maxRow) {
        return new Point(row + 1, 0)
      } else {
        return new Point(row, maxColumn)
      }
    }

    return screenPosition
  }

  getClipColumnDelta (bufferPosition, clipDirection) {
    const {row: bufferRow, column: bufferColumn} = bufferPosition
    const bufferLine = this.buffer.lineForRow(bufferRow)

    // Treat paired unicode characters as atomic...
    const previousCharacter = bufferLine[bufferColumn - 1]
    const character = bufferLine[bufferColumn]
    if (previousCharacter && character && isCharacterPair(previousCharacter, character)) {
      if (clipDirection === 'closest' || clipDirection === 'backward') {
        return -1
      } else {
        return 1
      }
    }

    // Clip atomic soft tabs...

    if (!this.atomicSoftTabs) return 0

    if (bufferColumn * this.ratioForCharacter(' ') > this.softWrapColumn) {
      return 0
    }

    for (let column = bufferColumn; column > 0; column--) {
      if (bufferLine[column] !== ' ') return 0
    }

    const previousTabStop = bufferColumn - (bufferColumn % this.tabLength)
    const nextTabStop = previousTabStop + this.tabLength

    // If there is a non-whitespace character before the next tab stop,
    // don't this whitespace as a soft tab
    for (let column = bufferColumn; column < nextTabStop; column++) {
      if (bufferLine[column] !== ' ') return 0
    }

    let clippedColumn
    if (clipDirection === 'closest') {
      if (bufferColumn - previousTabStop > this.tabLength / 2) {
        clippedColumn = nextTabStop
      } else {
        clippedColumn = previousTabStop
      }
    } else if (clipDirection === 'backward') {
      clippedColumn = previousTabStop
    } else if (clipDirection === 'forward') {
      clippedColumn = nextTabStop
    }

    return clippedColumn - bufferColumn
  }

  getText () {
    return this.getScreenLines().map((line) => line.lineText).join('\n')
  }

  lineLengthForScreenRow (screenRow) {
    return this.screenLineLengths[screenRow]
  }

  getLastScreenRow () {
    return this.screenLineLengths.length - 1
  }

  getScreenLineCount () {
    return this.screenLineLengths.length
  }

  getApproximateScreenLineCount () {
    return this.getScreenLineCount()
  }

  getRightmostScreenPosition () {
    return this.rightmostScreenPosition
  }

  getApproximateRightmostScreenPosition () {
    return this.getRightmostScreenPosition()
  }

  getScreenLines (screenStartRow = 0, screenEndRow = this.getScreenLineCount()) {
    return this.screenLineBuilder.buildScreenLines(screenStartRow, screenEndRow)
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

  bufferWillChange () {

  }

  bufferDidChange ({oldRange, newRange}) {
    let startRow = oldRange.start.row
    let oldEndRow = oldRange.end.row
    let newEndRow = newRange.end.row

    // Indent guides on sequences of blank lines are affected by the content of
    // adjacent lines.
    if (this.showIndentGuides) {
      while (startRow > 0) {
        if (this.buffer.lineLengthForRow(startRow - 1) > 0) break
        startRow--
      }

      while (newEndRow < this.buffer.getLastRow()) {
        if (this.buffer.lineLengthForRow(newEndRow + 1) > 0) break
        oldEndRow++
        newEndRow++
      }
    }

    return [this.updateSpatialIndex(startRow, oldEndRow + 1, newEndRow + 1)]
  }

  emitDidChangeSyncEvent (event) {
    this.emitter.emit('did-change-sync', event)
  }

  notifyObserversIfMarkerScreenPositionsChanged () {
    this.displayMarkerLayersById.forEach((layer) => {
      layer.notifyObserversIfMarkerScreenPositionsChanged()
    })
  }

  updateSpatialIndex (startBufferRow, oldEndBufferRow, newEndBufferRow) {
    const originalOldEndBufferRow = oldEndBufferRow
    startBufferRow = this.findBoundaryPrecedingBufferRow(startBufferRow)
    oldEndBufferRow = this.findBoundaryFollowingBufferRow(oldEndBufferRow)
    newEndBufferRow += (oldEndBufferRow - originalOldEndBufferRow)

    const startScreenRow = this.translateBufferPositionWithoutBufferClipping({row: startBufferRow, column: 0}, 'backward').row
    const oldEndScreenRow = this.translateBufferPositionWithoutBufferClipping({row: oldEndBufferRow, column: 0}, 'backward').row
    this.spatialIndex.spliceOld(
      {row: startBufferRow, column: 0},
      {row: oldEndBufferRow - startBufferRow, column: 0},
      {row: newEndBufferRow - startBufferRow, column: 0}
    )

    const folds = this.computeFoldsInBufferRowRange(startBufferRow, newEndBufferRow)

    const insertedScreenLineLengths = []
    let rightmostInsertedScreenPosition = Point(0, -1)
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

        // Are we in leading whitespace? If yes, record the *end* of the leading
        // whitespace if we've reached a non whitespace character. If no, record
        // the current column if it is a viable soft wrap boundary.
        if (firstNonWhitespaceScreenColumn < 0) {
          if (character !== ' ' && character !== '\t') {
            firstNonWhitespaceScreenColumn = screenColumn
          }
        } else {
          if (previousCharacter &&
              character &&
              this.isWrapBoundary(previousCharacter, character)) {
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

        const insertSoftLineBreak =
          screenLineWidth > 0 && characterWidth > 0 &&
          screenLineWidth + characterWidth > this.softWrapColumn &&
          previousCharacter && character &&
          !isCharacterPair(previousCharacter, character)

        // Terminate any pending tab sequence if we've reached a non-tab
        if (tabSequenceLength > 0 && (character !== '\t' || insertSoftLineBreak)) {
          this.spatialIndex.splice(
            Point(screenRow, tabSequenceStartScreenColumn),
            Point(0, tabSequenceLength),
            Point(0, screenColumn - tabSequenceStartScreenColumn)
          )
          tabSequenceLength = 0
          tabSequenceStartScreenColumn = -1
        }

        if (insertSoftLineBreak) {
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
          insertedScreenLineLengths.push(wrapColumn)
          if (wrapColumn > rightmostInsertedScreenPosition.column) {
            rightmostInsertedScreenPosition.row = screenRow
            rightmostInsertedScreenPosition.column = wrapColumn
          }
          screenRow++
          screenColumn = indentLength + (screenColumn - wrapColumn)
          screenLineWidth = (indentLength * this.ratioForCharacter(' ')) + (screenLineWidth - wrapWidth)
          lastWrapBoundaryScreenColumn = 0
          lastWrapBoundaryScreenLineWidth = 0
        }

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
            screenLineWidth += distanceToNextTabStop * this.ratioForCharacter(' ')
          } else {
            screenColumn++
            screenLineWidth += characterWidth
          }
          bufferColumn++
        }
      }

      screenColumn--
      insertedScreenLineLengths.push(screenColumn)
      if (screenColumn > rightmostInsertedScreenPosition.column) {
        rightmostInsertedScreenPosition.row = screenRow
        rightmostInsertedScreenPosition.column = screenColumn
      }

      bufferRow++
      bufferColumn = 0

      screenRow++
      screenColumn = 0
    }

    const oldScreenRowCount = oldEndScreenRow - startScreenRow
    spliceArray(
      this.screenLineLengths,
      startScreenRow,
      oldScreenRowCount,
      insertedScreenLineLengths
    )

    const lastRemovedScreenRow = startScreenRow + oldScreenRowCount
    if (rightmostInsertedScreenPosition.column > this.rightmostScreenPosition.column) {
      this.rightmostScreenPosition = rightmostInsertedScreenPosition
    } else if (lastRemovedScreenRow < this.rightmostScreenPosition.row) {
      this.rightmostScreenPosition.row += insertedScreenLineLengths.length - oldScreenRowCount
    } else if (startScreenRow <= this.rightmostScreenPosition.row) {
      this.rightmostScreenPosition = Point(0, 0)
      for (let row = 0, rowCount = this.screenLineLengths.length; row < rowCount; row++) {
        if (this.screenLineLengths[row] > this.rightmostScreenPosition.column) {
          this.rightmostScreenPosition.row = row
          this.rightmostScreenPosition.column = this.screenLineLengths[row]
        }
      }
    }

    spliceArray(
      this.cachedScreenLines,
      startScreenRow,
      oldScreenRowCount,
      new Array(insertedScreenLineLengths.length)
    )

    return {
      start: Point(startScreenRow, 0),
      oldExtent: Point(oldScreenRowCount, 0),
      newExtent: Point(insertedScreenLineLengths.length, 0)
    }
  }

  findBoundaryPrecedingBufferRow (bufferRow) {
    while (true) {
      let screenPosition = this.translateBufferPositionWithoutBufferClipping(Point(bufferRow, 0), 'backward')
      if (screenPosition.column === 0) {
        return this.translateScreenPositionWithoutBufferClipping(screenPosition, 'backward').row
      } else {
        let bufferPosition = this.translateScreenPositionWithoutBufferClipping(Point(screenPosition.row, 0), 'backward', false)
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
      let screenPosition = this.translateBufferPositionWithoutBufferClipping(Point(bufferRow, 0), 'forward')
      if (screenPosition.column === 0) {
        return bufferRow
      } else {
        const endOfScreenRow = Point(
          screenPosition.row,
          this.screenLineLengths[screenPosition.row]
        )
        bufferRow = this.translateScreenPositionWithoutBufferClipping(endOfScreenRow, 'backward', false).row + 1
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
