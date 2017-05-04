const {Patch} = require('superstring')
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
    this.emitter = new Emitter()
    this.screenLineBuilder = new ScreenLineBuilder(this)
    this.cachedScreenLines = []
    this.tagsByCode = new Map()
    this.codesByTag = new Map()
    this.nextOpenTagCode = -1
    this.textDecorationLayer = new EmptyDecorationLayer()
    this.displayMarkerLayersById = new Map()
    this.destroyed = false

    this.invisibles = params.invisibles != null ? params.invisibles : {}
    this.tabLength = params.tabLength != null ? params.tabLength : 4
    this.softWrapColumn = params.softWrapColumn != null ? Math.max(1, params.softWrapColumn) : Infinity
    this.softWrapHangingIndent = params.softWrapHangingIndent != null ? params.softWrapHangingIndent : 0
    this.showIndentGuides = params.showIndentGuides != null ? params.showIndentGuides : false
    this.ratioForCharacter = params.ratioForCharacter != null ? params.ratioForCharacter : unitRatio
    this.isWrapBoundary = params.isWrapBoundary != null ? params.isWrapBoundary : isWordStart
    this.foldCharacter = params.foldCharacter != null ? params.foldCharacter : '⋯'
    this.atomicSoftTabs = params.atomicSoftTabs != null ? params.atomicSoftTabs : true

    this.eolInvisibles = {
      '\r': this.invisibles.cr,
      '\n': this.invisibles.eol,
      '\r\n': this.invisibles.cr + this.invisibles.eol
    }

    this.foldsMarkerLayer = params.foldsMarkerLayer || buffer.addMarkerLayer({
      maintainHistory: false,
      persistent: true,
      destroyInvalidatedMarkers: true
    })
    this.foldIdCounter = params.foldIdCounter || 1

    if (params.spatialIndex) {
      this.spatialIndex = params.spatialIndex
      this.tabCounts = params.tabCounts
      this.screenLineLengths = params.screenLineLengths
      this.rightmostScreenPosition = params.rightmostScreenPosition
      this.indexedBufferRowCount = params.indexedBufferRowCount
    } else {
      this.spatialIndex = new Patch({mergeAdjacentHunks: false})
      this.tabCounts = []
      this.screenLineLengths = []
      this.rightmostScreenPosition = Point(0, 0)
      this.indexedBufferRowCount = 0
    }
  }

  static deserialize (buffer, params) {
    const foldsMarkerLayer = buffer.getMarkerLayer(params.foldsMarkerLayerId)
    return new DisplayLayer(params.id, buffer, {foldsMarkerLayer})
  }

  serialize () {
    return {
      id: this.id,
      foldsMarkerLayerId: this.foldsMarkerLayer.id,
      foldIdCounter: this.foldIdCounter
    }
  }

  reset (params) {
    if (!this.isDestroyed() && this.setParams(params)) {
      this.clearSpatialIndex()
      this.emitter.emit('did-reset')
      this.notifyObserversIfMarkerScreenPositionsChanged()
    }
  }

  copy () {
    const copyId = this.buffer.nextDisplayLayerId++
    const copy = new DisplayLayer(copyId, this.buffer, {
      foldsMarkerLayer: this.foldsMarkerLayer.copy(),
      foldIdCounter: this.foldIdCounter,
      spatialIndex: this.spatialIndex.copy(),
      tabCounts: this.tabCounts.slice(),
      screenLineLengths: this.screenLineLengths.slice(),
      rightmostScreenPosition: this.rightmostScreenPosition.copy(),
      indexedBufferRowCount: this.indexedBufferRowCount,
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
    if (this.destroyed) return
    this.destroyed = true
    this.clearSpatialIndex()
    this.foldsMarkerLayer.destroy()
    this.displayMarkerLayersById.forEach((layer) => layer.destroy())
    if (this.decorationLayerDisposable) this.decorationLayerDisposable.dispose()
    delete this.buffer.displayLayers[this.id]
  }

  isDestroyed () {
    return this.destroyed
  }

  clearSpatialIndex () {
    this.indexedBufferRowCount = 0
    this.spatialIndex.spliceOld(Point.ZERO, Point.INFINITY, Point.INFINITY)
    this.cachedScreenLines.length = 0
    this.screenLineLengths.length = 0
    this.tabCounts.length = 0
  }

  doBackgroundWork (deadline) {
    this.populateSpatialIndexIfNeeded(this.buffer.getLineCount(), Infinity, deadline)
    return this.indexedBufferRowCount < this.buffer.getLineCount()
  }

  getTextDecorationLayer () {
    return this.textDecorationLayer
  }

  setTextDecorationLayer (textDecorationLayer) {
    this.cachedScreenLines.length = 0
    this.textDecorationLayer = textDecorationLayer
    if (typeof textDecorationLayer.onDidInvalidateRange === 'function') {
      this.decorationLayerDisposable = textDecorationLayer.onDidInvalidateRange((bufferRange) => {
        bufferRange = Range.fromObject(bufferRange)
        this.populateSpatialIndexIfNeeded(bufferRange.end.row + 1, Infinity)
        const startBufferRow = this.findBoundaryPrecedingBufferRow(bufferRange.start.row)
        const endBufferRow = this.findBoundaryFollowingBufferRow(bufferRange.end.row + 1)
        const startRow = this.translateBufferPositionWithSpatialIndex(Point(startBufferRow, 0), 'backward').row
        const endRow = this.translateBufferPositionWithSpatialIndex(Point(endBufferRow, 0), 'backward').row
        const extent = Point(endRow - startRow, 0)
        spliceArray(this.cachedScreenLines, startRow, extent.row, new Array(extent.row))
        this.emitDidChangeSyncEvent([{
          start: Point(startRow, 0),
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

  bufferRangeForFold (foldId) {
    return this.foldsMarkerLayer.getMarkerRange(foldId)
  }

  foldBufferRange (bufferRange) {
    bufferRange = Range.fromObject(bufferRange)
    const containingFoldMarkers = this.foldsMarkerLayer.findMarkers({containsRange: bufferRange})
    if (containingFoldMarkers.length === 0) {
      this.populateSpatialIndexIfNeeded(bufferRange.end.row + 1, Infinity)
    }
    const foldId = this.foldsMarkerLayer.markRange(bufferRange, {invalidate: 'overlap', exclusive: true}).id
    if (containingFoldMarkers.length === 0) {
      const foldStartRow = bufferRange.start.row
      const foldEndRow = bufferRange.end.row + 1
      this.emitDidChangeSyncEvent([
        this.updateSpatialIndex(foldStartRow, foldEndRow, foldEndRow, Infinity)
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
    }

    this.populateSpatialIndexIfNeeded(combinedRangeEnd.row + 1, Infinity)

    for (const foldMarker of foldMarkers) {
      foldMarker.destroy()
    }

    this.emitDidChangeSyncEvent([this.updateSpatialIndex(
      combinedRangeStart.row,
      combinedRangeEnd.row + 1,
      combinedRangeEnd.row + 1,
      Infinity
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
    this.populateSpatialIndexIfNeeded(bufferPosition.row + 1, Infinity)
    const clipDirection = options && options.clipDirection || 'closest'
    let screenPosition = this.translateBufferPositionWithSpatialIndex(bufferPosition, clipDirection)
    const tabCount = this.tabCounts[screenPosition.row]
    if (tabCount > 0) {
      screenPosition = this.expandHardTabs(screenPosition, bufferPosition, tabCount)
    }
    const columnDelta = this.getClipColumnDelta(bufferPosition, clipDirection)
    if (columnDelta !== 0) {
      return Point(screenPosition.row, screenPosition.column + columnDelta)
    } else {
      return Point.fromObject(screenPosition)
    }
  }

  translateBufferPositionWithSpatialIndex (bufferPosition, clipDirection) {
    let hunk = this.spatialIndex.hunkForOldPosition(bufferPosition)
    if (hunk) {
      if (compare(bufferPosition, hunk.oldEnd) < 0) {
        if (compare(hunk.oldStart, bufferPosition) === 0) {
          return hunk.newStart
        } else { // hunk is a fold
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
    Point.assertValid(screenPosition)
    const clipDirection = options && options.clipDirection || 'closest'
    const skipSoftWrapIndentation = options && options.skipSoftWrapIndentation
    this.populateSpatialIndexIfNeeded(this.buffer.getLineCount(), screenPosition.row + 1)
    screenPosition = this.constrainScreenPosition(screenPosition, clipDirection)
    const tabCount = this.tabCounts[screenPosition.row]
    if (tabCount > 0) {
      screenPosition = this.collapseHardTabs(screenPosition, tabCount, clipDirection)
    }
    const bufferPosition = this.translateScreenPositionWithSpatialIndex(screenPosition, clipDirection, skipSoftWrapIndentation)

    if (global.atom && bufferPosition.row >= this.buffer.getLineCount()) {
      global.atom.assert(false, 'Invalid translated buffer row', {
        bufferPosition, bufferLineCount: this.buffer.getLineCount()
      })
      return this.buffer.getEndPosition()
    }

    const columnDelta = this.getClipColumnDelta(bufferPosition, clipDirection)
    if (columnDelta !== 0) {
      return Point(bufferPosition.row, bufferPosition.column + columnDelta)
    } else {
      return Point.fromObject(bufferPosition)
    }
  }

  translateScreenPositionWithSpatialIndex (screenPosition, clipDirection, skipSoftWrapIndentation) {
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (compare(screenPosition, hunk.newEnd) < 0) {
        if (this.isSoftWrapHunk(hunk)) {
          if (clipDirection === 'backward' && !skipSoftWrapIndentation ||
              clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
            return this.translateScreenPositionWithSpatialIndex(traverse(hunk.newStart, Point(0, -1)), clipDirection, skipSoftWrapIndentation)
          } else {
            return hunk.oldStart
          }
        } else { // Hunk is a fold. Since folds are 1 character on screen, we're at the start.
          return hunk.oldStart
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
    return this.translateBufferPosition(
      this.translateScreenPosition(screenPosition, options),
      options
    )
  }

  constrainScreenPosition (screenPosition, clipDirection) {
    let {row, column} = screenPosition

    if (row < 0) {
      return new Point(0, 0)
    }

    const maxRow = this.screenLineLengths.length - 1
    if (row > maxRow) {
      return new Point(maxRow, this.screenLineLengths[maxRow])
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

  expandHardTabs (targetScreenPosition, targetBufferPosition, tabCount) {
    const screenRowStart = Point(targetScreenPosition.row, 0)
    const hunks = this.spatialIndex.getHunksInNewRange(screenRowStart, targetScreenPosition)
    let hunkIndex = 0
    let unexpandedScreenColumn = 0
    let expandedScreenColumn = 0
    let {row: bufferRow, column: bufferColumn} = this.translateScreenPositionWithSpatialIndex(screenRowStart)
    let bufferLine = this.buffer.lineForRow(bufferRow)

    while (tabCount > 0) {
      if (unexpandedScreenColumn === targetScreenPosition.column) {
        break
      }

      let nextHunk = hunks[hunkIndex]
      if (nextHunk && nextHunk.oldStart.row === bufferRow && nextHunk.oldStart.column === bufferColumn) {
        if (this.isSoftWrapHunk(nextHunk)) {
          if (hunkIndex !== 0) throw new Error('Unexpected soft wrap hunk')
          unexpandedScreenColumn = hunks[0].newEnd.column
          expandedScreenColumn = unexpandedScreenColumn
        } else {
          ({row: bufferRow, column: bufferColumn} = nextHunk.oldEnd)
          bufferLine = this.buffer.lineForRow(bufferRow)
          unexpandedScreenColumn++
          expandedScreenColumn++
        }

        hunkIndex++
        continue
      }

      if (bufferLine[bufferColumn] === '\t') {
        expandedScreenColumn += (this.tabLength - (expandedScreenColumn % this.tabLength))
        tabCount--
      } else {
        expandedScreenColumn++
      }
      unexpandedScreenColumn++
      bufferColumn++
    }

    expandedScreenColumn += targetScreenPosition.column - unexpandedScreenColumn
    if (expandedScreenColumn === targetScreenPosition.column) {
      return targetScreenPosition
    } else {
      return Point(targetScreenPosition.row, expandedScreenColumn)
    }
  }

  collapseHardTabs (targetScreenPosition, tabCount, clipDirection) {
    const screenRowStart = Point(targetScreenPosition.row, 0)
    const screenRowEnd = Point(targetScreenPosition.row, this.screenLineLengths[targetScreenPosition.row])

    const hunks = this.spatialIndex.getHunksInNewRange(screenRowStart, screenRowEnd)
    let hunkIndex = 0
    let unexpandedScreenColumn = 0
    let expandedScreenColumn = 0
    let {row: bufferRow, column: bufferColumn} = this.translateScreenPositionWithSpatialIndex(screenRowStart)
    let bufferLine = this.buffer.lineForRow(bufferRow)

    while (tabCount > 0) {
      if (expandedScreenColumn === targetScreenPosition.column) {
        break
      }

      let nextHunk = hunks[hunkIndex]
      if (nextHunk && nextHunk.oldStart.row === bufferRow && nextHunk.oldStart.column === bufferColumn) {
        if (this.isSoftWrapHunk(nextHunk)) {
          if (hunkIndex !== 0) throw new Error('Unexpected soft wrap hunk')
          unexpandedScreenColumn = Math.min(targetScreenPosition.column, nextHunk.newEnd.column)
          expandedScreenColumn = unexpandedScreenColumn
        } else {
          ({row: bufferRow, column: bufferColumn} = nextHunk.oldEnd)
          bufferLine = this.buffer.lineForRow(bufferRow)
          unexpandedScreenColumn++
          expandedScreenColumn++
        }
        hunkIndex++
        continue
      }

      if (bufferLine[bufferColumn] === '\t') {
        const nextTabStopColumn = expandedScreenColumn + this.tabLength - (expandedScreenColumn % this.tabLength)
        if (nextTabStopColumn > targetScreenPosition.column) {
          if (clipDirection === 'backward') {
            return Point(targetScreenPosition.row, unexpandedScreenColumn)
          } else if (clipDirection === 'forward') {
            return Point(targetScreenPosition.row, unexpandedScreenColumn + 1)
          } else {
            if (targetScreenPosition.column - expandedScreenColumn > nextTabStopColumn - targetScreenPosition.column) {
              return Point(targetScreenPosition.row, unexpandedScreenColumn)
            } else {
              return Point(targetScreenPosition.row, unexpandedScreenColumn + 1)
            }
          }
        }
        expandedScreenColumn = nextTabStopColumn
        tabCount--
      } else {
        expandedScreenColumn++
      }
      unexpandedScreenColumn++
      bufferColumn++
    }

    unexpandedScreenColumn += targetScreenPosition.column - expandedScreenColumn
    if (unexpandedScreenColumn === targetScreenPosition.column) {
      return targetScreenPosition
    } else {
      return Point(targetScreenPosition.row, unexpandedScreenColumn)
    }
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

    for (let column = bufferColumn; column >= 0; column--) {
      if (bufferLine[column] !== ' ') return 0
    }

    const previousTabStop = bufferColumn - (bufferColumn % this.tabLength)
    if (bufferColumn === previousTabStop) return 0
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

  getText (startRow, endRow) {
    return this.getScreenLines(startRow, endRow).map((line) => line.lineText).join('\n')
  }

  lineLengthForScreenRow (screenRow) {
    return this.screenLineLengths[screenRow]
  }

  getLastScreenRow () {
    this.populateSpatialIndexIfNeeded(this.buffer.getLineCount(), Infinity)
    return this.screenLineLengths.length - 1
  }

  getScreenLineCount () {
    this.populateSpatialIndexIfNeeded(this.buffer.getLineCount(), Infinity)
    return this.screenLineLengths.length
  }

  getApproximateScreenLineCount () {
    if (this.indexedBufferRowCount > 0) {
      return Math.floor(this.buffer.getLineCount() * this.screenLineLengths.length / this.indexedBufferRowCount)
    } else {
      return this.buffer.getLineCount()
    }
  }

  getRightmostScreenPosition () {
    this.populateSpatialIndexIfNeeded(this.buffer.getLineCount(), Infinity)
    return this.rightmostScreenPosition
  }

  getApproximateRightmostScreenPosition () {
    return this.rightmostScreenPosition
  }

  getScreenLine (screenRow) {
    return this.cachedScreenLines[screenRow] || this.getScreenLines(screenRow, screenRow + 1)[0]
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

  bufferWillChange (change) {
    const lineCount = this.buffer.getLineCount()
    let endRow = change.oldRange.end.row
    while (endRow + 1 < lineCount && this.buffer.lineLengthForRow(endRow + 1) === 0) {
      endRow++
    }
    this.populateSpatialIndexIfNeeded(endRow + 1, Infinity)
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

    const combinedChanges = new Patch()
    this.indexedBufferRowCount += newEndRow - oldEndRow
    const {start, oldExtent, newExtent} = this.updateSpatialIndex(startRow, oldEndRow + 1, newEndRow + 1, Infinity)
    combinedChanges.splice(start, oldExtent, newExtent)

    for (let bufferRange of this.textDecorationLayer.getInvalidatedRanges()) {
      bufferRange = Range.fromObject(bufferRange)
      this.populateSpatialIndexIfNeeded(bufferRange.end.row + 1, Infinity)
      const startBufferRow = this.findBoundaryPrecedingBufferRow(bufferRange.start.row)
      const endBufferRow = this.findBoundaryFollowingBufferRow(bufferRange.end.row + 1)
      const startRow = this.translateBufferPositionWithSpatialIndex(Point(startBufferRow, 0), 'backward').row
      const endRow = this.translateBufferPositionWithSpatialIndex(Point(endBufferRow, 0), 'backward').row
      const extent = Point(endRow - startRow, 0)
      spliceArray(this.cachedScreenLines, startRow, extent.row, new Array(extent.row))
      combinedChanges.splice(Point(startRow, 0), extent, extent)
    }

    return Object.freeze(combinedChanges.getHunks().map((hunk) => {
      return {
        start: Point.fromObject(hunk.newStart),
        oldExtent: traversal(hunk.oldEnd, hunk.oldStart),
        newExtent: traversal(hunk.newEnd, hunk.newStart)
      }
    }))
  }

  emitDidChangeSyncEvent (event) {
    this.emitter.emit('did-change-sync', event)
  }

  notifyObserversIfMarkerScreenPositionsChanged () {
    this.displayMarkerLayersById.forEach((layer) => {
      layer.notifyObserversIfMarkerScreenPositionsChanged()
    })
  }

  updateSpatialIndex (startBufferRow, oldEndBufferRow, newEndBufferRow, endScreenRow, deadline = NullDeadline) {
    const originalOldEndBufferRow = oldEndBufferRow
    startBufferRow = this.findBoundaryPrecedingBufferRow(startBufferRow)
    oldEndBufferRow = this.findBoundaryFollowingBufferRow(oldEndBufferRow)
    newEndBufferRow += (oldEndBufferRow - originalOldEndBufferRow)

    const startScreenRow = this.translateBufferPositionWithSpatialIndex({row: startBufferRow, column: 0}, 'backward').row
    const oldEndScreenRow = this.translateBufferPositionWithSpatialIndex({row: oldEndBufferRow, column: 0}, 'backward').row
    this.spatialIndex.spliceOld(
      {row: startBufferRow, column: 0},
      {row: oldEndBufferRow - startBufferRow, column: 0},
      {row: newEndBufferRow - startBufferRow, column: 0}
    )

    const folds = this.computeFoldsInBufferRowRange(startBufferRow, newEndBufferRow)

    const insertedScreenLineLengths = []
    const insertedTabCounts = []
    const currentScreenLineTabColumns = []
    let rightmostInsertedScreenPosition = Point(0, -1)
    let bufferRow = startBufferRow
    let screenRow = startScreenRow
    let bufferColumn = 0
    let unexpandedScreenColumn = 0
    let expandedScreenColumn = 0

    while (true) {
      if (bufferRow >= newEndBufferRow) break
      if (screenRow >= endScreenRow && bufferColumn === 0) break
      if (deadline.timeRemaining() < 2) break
      let bufferLine = this.buffer.lineForRow(bufferRow)
      if (bufferLine == null) break
      let bufferLineLength = bufferLine.length
      currentScreenLineTabColumns.length = 0
      let screenLineWidth = 0
      let lastWrapBoundaryUnexpandedScreenColumn = 0
      let lastWrapBoundaryExpandedScreenColumn = 0
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
            firstNonWhitespaceScreenColumn = expandedScreenColumn
          }
        } else {
          if (previousCharacter &&
              character &&
              this.isWrapBoundary(previousCharacter, character)) {
            lastWrapBoundaryUnexpandedScreenColumn = unexpandedScreenColumn
            lastWrapBoundaryExpandedScreenColumn = expandedScreenColumn
            lastWrapBoundaryScreenLineWidth = screenLineWidth
          }
        }

        // Determine the on-screen width of the character for soft-wrap calculations
        let characterWidth
        if (character === '\t') {
          const distanceToNextTabStop = this.tabLength - (expandedScreenColumn % this.tabLength)
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

        if (insertSoftLineBreak) {
          let indentLength = (firstNonWhitespaceScreenColumn < this.softWrapColumn)
            ? Math.max(0, firstNonWhitespaceScreenColumn)
            : 0
          if (indentLength + this.softWrapHangingIndent < this.softWrapColumn) {
            indentLength += this.softWrapHangingIndent
          }

          const unexpandedWrapColumn = lastWrapBoundaryUnexpandedScreenColumn || unexpandedScreenColumn
          const expandedWrapColumn = lastWrapBoundaryExpandedScreenColumn || expandedScreenColumn
          const wrapWidth = lastWrapBoundaryScreenLineWidth || screenLineWidth
          this.spatialIndex.splice(
            Point(screenRow, unexpandedWrapColumn),
            Point.ZERO,
            Point(1, indentLength)
          )

          insertedScreenLineLengths.push(expandedWrapColumn)
          if (expandedWrapColumn > rightmostInsertedScreenPosition.column) {
            rightmostInsertedScreenPosition.row = screenRow
            rightmostInsertedScreenPosition.column = expandedWrapColumn
          }
          screenRow++

          // To determine the expanded screen column following the wrap, we need
          // to re-expand each tab following the wrap boundary, because tabs may
          // take on different lengths due to starting at different screen columns.
          let unexpandedScreenColumnAfterLastTab = indentLength
          let expandedScreenColumnAfterLastTab = indentLength
          let tabCountPrecedingWrap = 0
          for (let i = 0; i < currentScreenLineTabColumns.length; i++) {
            const tabColumn = currentScreenLineTabColumns[i]
            if (tabColumn < unexpandedWrapColumn) {
              tabCountPrecedingWrap++
            } else {
              const tabColumnAfterWrap = indentLength + tabColumn - unexpandedWrapColumn
              expandedScreenColumnAfterLastTab += (tabColumnAfterWrap - unexpandedScreenColumnAfterLastTab)
              expandedScreenColumnAfterLastTab += this.tabLength - (expandedScreenColumnAfterLastTab % this.tabLength)
              unexpandedScreenColumnAfterLastTab = tabColumnAfterWrap + 1
              currentScreenLineTabColumns[i - tabCountPrecedingWrap] = tabColumnAfterWrap
            }
          }
          insertedTabCounts.push(tabCountPrecedingWrap)
          currentScreenLineTabColumns.length -= tabCountPrecedingWrap

          unexpandedScreenColumn = unexpandedScreenColumn - unexpandedWrapColumn + indentLength
          expandedScreenColumn = expandedScreenColumnAfterLastTab + unexpandedScreenColumn - unexpandedScreenColumnAfterLastTab
          screenLineWidth = (indentLength * this.ratioForCharacter(' ')) + (screenLineWidth - wrapWidth)

          lastWrapBoundaryUnexpandedScreenColumn = 0
          lastWrapBoundaryExpandedScreenColumn = 0
          lastWrapBoundaryScreenLineWidth = 0
        }

        // If there is a fold at this position, splice it into the spatial index
        // and jump to the end of the fold.
        if (foldEnd) {
          this.spatialIndex.splice(
            {row: screenRow, column: unexpandedScreenColumn},
            traversal(foldEnd, {row: bufferRow, column: bufferColumn}),
            {row: 0, column: 1}
          )
          unexpandedScreenColumn++
          expandedScreenColumn++
          screenLineWidth += characterWidth
          bufferRow = foldEnd.row
          bufferColumn = foldEnd.column
          bufferLine = this.buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
        } else {
          // If there is no fold at this position, check if we need to handle
          // a hard tab at this position and advance by a single buffer column.
          if (character === '\t') {
            currentScreenLineTabColumns.push(unexpandedScreenColumn)
            const distanceToNextTabStop = this.tabLength - (expandedScreenColumn % this.tabLength)
            expandedScreenColumn += distanceToNextTabStop
            screenLineWidth += distanceToNextTabStop * this.ratioForCharacter(' ')
          } else {
            expandedScreenColumn++
            screenLineWidth += characterWidth
          }
          unexpandedScreenColumn++
          bufferColumn++
        }
      }

      expandedScreenColumn--
      insertedScreenLineLengths.push(expandedScreenColumn)
      insertedTabCounts.push(currentScreenLineTabColumns.length)
      if (expandedScreenColumn > rightmostInsertedScreenPosition.column) {
        rightmostInsertedScreenPosition.row = screenRow
        rightmostInsertedScreenPosition.column = expandedScreenColumn
      }

      bufferRow++
      bufferColumn = 0

      screenRow++
      unexpandedScreenColumn = 0
      expandedScreenColumn = 0
    }

    if (bufferRow > this.indexedBufferRowCount) {
      this.indexedBufferRowCount = bufferRow
      if (bufferRow === this.buffer.getLineCount()) {
        this.spatialIndex.rebalance()
      }
    }

    const oldScreenRowCount = oldEndScreenRow - startScreenRow
    spliceArray(
      this.screenLineLengths,
      startScreenRow,
      oldScreenRowCount,
      insertedScreenLineLengths
    )
    spliceArray(
      this.tabCounts,
      startScreenRow,
      oldScreenRowCount,
      insertedTabCounts
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

  populateSpatialIndexIfNeeded (endBufferRow, endScreenRow, deadline = NullDeadline) {
    if (endBufferRow > this.indexedBufferRowCount && endScreenRow > this.screenLineLengths.length) {
      this.updateSpatialIndex(
        this.indexedBufferRowCount,
        endBufferRow,
        endBufferRow,
        endScreenRow,
        deadline
      )
    }
  }

  findBoundaryPrecedingBufferRow (bufferRow) {
    while (true) {
      if (bufferRow === 0) return 0
      let screenPosition = this.translateBufferPositionWithSpatialIndex(Point(bufferRow, 0), 'backward')
      let bufferPosition = this.translateScreenPositionWithSpatialIndex(Point(screenPosition.row, 0), 'backward', false)
      if (screenPosition.column === 0 && bufferPosition.column === 0) {
        return bufferPosition.row
      } else {
        bufferRow = bufferPosition.row
      }
    }
  }

  findBoundaryFollowingBufferRow (bufferRow) {
    while (true) {
      let screenPosition = this.translateBufferPositionWithSpatialIndex(Point(bufferRow, 0), 'forward')
      if (screenPosition.column === 0) {
        return bufferRow
      } else {
        const endOfScreenRow = Point(
          screenPosition.row,
          this.screenLineLengths[screenPosition.row]
        )
        bufferRow = this.translateScreenPositionWithSpatialIndex(endOfScreenRow, 'forward', false).row + 1
      }
    }
  }

  findBoundaryFollowingScreenRow (screenRow) {
    while (true) {
      let bufferPosition = this.translateScreenPositionWithSpatialIndex(Point(screenRow, 0), 'forward')
      if (bufferPosition.column === 0) {
        return screenRow
      } else {
        const endOfBufferRow = Point(
          bufferPosition.row,
          this.buffer.lineLengthForRow(bufferPosition.row)
        )
        screenRow = this.translateBufferPositionWithSpatialIndex(endOfBufferRow, 'forward').row + 1
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

    // If the given buffer range exceeds the indexed range, we need to ensure
    // we consider any folds that intersect the combined row range of the
    // initially-queried folds, since we couldn't use the index to expand the
    // row range to account for these extra folds ahead of time.
    if (endBufferRow >= this.indexedBufferRowCount) {
      for (let i = 0; i < foldMarkers.length; i++) {
        const marker = foldMarkers[i]
        const nextMarker = foldMarkers[i + 1]
        if (marker.getEndPosition().row >= endBufferRow &&
            (!nextMarker || nextMarker.getEndPosition().row < marker.getEndPosition().row)) {
          const intersectingMarkers = this.foldsMarkerLayer.findMarkers({
            intersectsRow: marker.getEndPosition().row
          })
          endBufferRow = marker.getEndPosition().row + 1
          foldMarkers.splice(i, foldMarkers.length - i, ...intersectingMarkers)
        }
      }
    }

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

  setParams (params) {
    let paramsChanged = false
    if (params.hasOwnProperty('tabLength') && params.tabLength !== this.tabLength) {
      paramsChanged = true
      this.tabLength = params.tabLength
    }
    if (params.hasOwnProperty('invisibles') && !invisiblesEqual(params.invisibles, this.invisibles)) {
      paramsChanged = true
      this.invisibles = params.invisibles
      this.eolInvisibles = {
        '\r': this.invisibles.cr,
        '\n': this.invisibles.eol,
        '\r\n': this.invisibles.cr + this.invisibles.eol
      }
    }
    if (params.hasOwnProperty('showIndentGuides') && params.showIndentGuides !== this.showIndentGuides) {
      paramsChanged = true
      this.showIndentGuides = params.showIndentGuides
    }
    if (params.hasOwnProperty('softWrapColumn')) {
      let softWrapColumn = params.softWrapColumn != null
        ? Math.max(1, params.softWrapColumn)
        : Infinity
      if (softWrapColumn !== this.softWrapColumn) {
        paramsChanged = true
        this.softWrapColumn = softWrapColumn
      }
    }
    if (params.hasOwnProperty('softWrapHangingIndent') && params.softWrapHangingIndent !== this.softWrapHangingIndent) {
      paramsChanged = true
      this.softWrapHangingIndent = params.softWrapHangingIndent
    }
    if (params.hasOwnProperty('ratioForCharacter') && params.ratioForCharacter !== this.ratioForCharacter) {
      paramsChanged = true
      this.ratioForCharacter = params.ratioForCharacter
    }
    if (params.hasOwnProperty('isWrapBoundary') && params.isWrapBoundary !== this.isWrapBoundary) {
      paramsChanged = true
      this.isWrapBoundary = params.isWrapBoundary
    }
    if (params.hasOwnProperty('foldCharacter') && params.foldCharacter !== this.foldCharacter) {
      paramsChanged = true
      this.foldCharacter = params.foldCharacter
    }
    if (params.hasOwnProperty('atomicSoftTabs') && params.atomicSoftTabs !== this.atomicSoftTabs) {
      paramsChanged = true
      this.atomicSoftTabs = params.atomicSoftTabs
    }
    return paramsChanged
  }

  isSoftWrapHunk (hunk) {
    return isEqual(hunk.oldStart, hunk.oldEnd)
  }
}

function invisiblesEqual (left, right) {
  let leftKeys = Object.keys(left)
  let rightKeys = Object.keys(right)
  if (leftKeys.length !== rightKeys.length) return false
  for (let key of leftKeys) {
    if (left[key] !== right[key]) return false
  }
  return true
}

function isWordStart (previousCharacter, character) {
  return (previousCharacter === ' ' || previousCharacter === '\t') &&
    (character !== ' ' && character !== '\t')
}

function unitRatio () {
  return 1
}

const NullDeadline = {
  didTimeout: false,
  timeRemaining () { return Infinity }
}
