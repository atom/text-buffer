const {MarkerIndex} = require('superstring')
const {Emitter} = require('event-kit')
const {compare: comparePoints, isEqual: isEqualPoint, min: minPoint} = require('../../src/point-helpers')
const Point = require('../../src/point')
const Range = require('../../src/range')
const {MAX_BUILT_IN_SCOPE_ID} = require('../../src/constants')

module.exports =
class TestDecorationLayer {
  constructor (decorations, buffer, random) {
    this.buffer = buffer
    this.random = random
    // TODO: Set this back to 1 when we introduce the composite decoration layer
    this.nextMarkerId = MAX_BUILT_IN_SCOPE_ID + 1
    this.markerIndex = new MarkerIndex()
    this.classNamesByScopeId = new Map()
    this.emitter = new Emitter()

    for (let value of decorations) {
      const className = value[0]
      const [rangeStart, rangeEnd] = Array.from(value[1])
      const markerId = this.getNextMarkerId()
      this.markerIndex.insert(markerId, Point.fromObject(rangeStart), Point.fromObject(rangeEnd))
      this.classNamesByScopeId.set(markerId, className)
    }

    if (this.buffer) {
      this.buffer.registerTextDecorationLayer(this)
    }
  }

  getNextMarkerId () {
    const nextMarkerId = this.nextMarkerId
    this.nextMarkerId += 2
    return nextMarkerId
  }

  classNameForScopeId (scopeId) {
    return this.classNamesByScopeId.get(scopeId)
  }

  buildIterator () {
    return new TestDecorationLayerIterator(this)
  }

  getInvalidatedRanges () { return this.invalidatedRanges }

  onDidInvalidateRange (fn) {
    return this.emitter.on('did-invalidate-range', fn)
  }

  emitInvalidateRangeEvent (range) {
    return this.emitter.emit('did-invalidate-range', range)
  }

  bufferDidChange ({oldRange, newRange}) {
    this.invalidatedRanges = [Range.fromObject(newRange)]
    const {inside, overlap} = this.markerIndex.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
    overlap.forEach((id) => this.invalidatedRanges.push(this.markerIndex.getRange(id)))
    inside.forEach((id) => this.invalidatedRanges.push(this.markerIndex.getRange(id)))

    this.insertRandomDecorations(oldRange, newRange)
  }

  insertRandomDecorations (oldRange, newRange) {
    if (this.invalidatedRanges == null) { this.invalidatedRanges = [] }

    const j = this.random(5)
    for (let i = 0; i < j; i++) {
      const markerId = this.getNextMarkerId()
      const className = String.fromCharCode('a'.charCodeAt(0) + this.random(27))
      this.classNamesByScopeId.set(markerId, className)
      const range = this.getRandomRangeCloseTo(oldRange.union(newRange))
      this.markerIndex.insert(markerId, range.start, range.end)
      this.invalidatedRanges.push(range)
    }
  }

  getRandomRangeCloseTo (range) {
    let minRow
    if (this.random(10) < 7) {
      minRow = this.constrainRow(range.start.row + this.random.intBetween(-20, 20))
    } else {
      minRow = 0
    }

    let maxRow
    if (this.random(10) < 7) {
      maxRow = this.constrainRow(range.end.row + this.random.intBetween(-20, 20))
    } else {
      maxRow = this.buffer.getLastRow()
    }

    const startRow = this.random.intBetween(minRow, maxRow)
    const endRow = this.random.intBetween(startRow, maxRow)
    const startColumn = this.random(this.buffer.lineForRow(startRow).length + 1)
    const endColumn = this.random(this.buffer.lineForRow(endRow).length + 1)
    return Range(Point(startRow, startColumn), Point(endRow, endColumn))
  }

  constrainRow (row) {
    return Math.max(0, Math.min(this.buffer.getLastRow(), row))
  }
}

class TestDecorationLayerIterator {
  constructor (layer) {
    this.layer = layer
    const {markerIndex, classNamesByScopeId} = this.layer

    const emptyMarkers = []
    const nonEmptyMarkers = []
    for (let key of classNamesByScopeId.keys()) {
      const id = parseInt(key)
      if (isEqualPoint(markerIndex.getStart(id), markerIndex.getEnd(id))) {
        emptyMarkers.push(id)
      } else {
        nonEmptyMarkers.push(id)
      }
    }

    emptyMarkers.sort((a, b) => comparePoints(markerIndex.getStart(a), markerIndex.getStart(b)) || (a - b))

    const markersSortedByStart = nonEmptyMarkers.slice().sort((a, b) => comparePoints(markerIndex.getStart(a), markerIndex.getStart(b)) || (a - b))

    const markersSortedByEnd = nonEmptyMarkers.slice().sort((a, b) => comparePoints(markerIndex.getEnd(a), markerIndex.getEnd(b)) || (b - a))

    this.boundaries = []

    const nextEmptyMarkerStart = () => (emptyMarkers.length > 0) && markerIndex.getStart(emptyMarkers[0])
    const nextMarkerStart = () => (markersSortedByStart.length > 0) && markerIndex.getStart(markersSortedByStart[0])
    const nextMarkerEnd = () => (markersSortedByEnd.length > 0) && markerIndex.getEnd(markersSortedByEnd[0])

    while ((emptyMarkers.length > 0) || (markersSortedByStart.length > 0) || (markersSortedByEnd.length > 0)) {
      let boundary = {
        position: Point.INFINITY,
        closeScopeIds: [],
        openScopeIds: []
      }

      if (nextMarkerStart()) {
        boundary.position = minPoint(boundary.position, nextMarkerStart())
      }
      if (nextEmptyMarkerStart()) {
        boundary.position = minPoint(boundary.position, nextEmptyMarkerStart())
      }
      if (nextMarkerEnd()) {
        boundary.position = minPoint(boundary.position, nextMarkerEnd())
      }

      while (nextMarkerEnd() && isEqualPoint(nextMarkerEnd(), boundary.position)) {
        boundary.closeScopeIds.push(markersSortedByEnd.shift())
      }

      const emptyScopeIds = []
      while (nextEmptyMarkerStart() && isEqualPoint(nextEmptyMarkerStart(), boundary.position)) {
        emptyScopeIds.push(emptyMarkers.shift())
      }

      if (emptyScopeIds.length > 0) {
        boundary.openScopeIds.push(...emptyScopeIds)
        this.boundaries.push(boundary)
        boundary = {
          position: boundary.position,
          closeScopeIds: [],
          openScopeIds: []
        }
        boundary.closeScopeIds.push(...emptyScopeIds)
      }

      while (nextMarkerStart() && isEqualPoint(nextMarkerStart(), boundary.position)) {
        boundary.openScopeIds.push(markersSortedByStart.shift())
      }

      this.boundaries.push(boundary)
    }
  }

  seek (position) {
    const containingScopeIds = []
    for (let index = 0; index < this.boundaries.length; index++) {
      const boundary = this.boundaries[index]
      if (comparePoints(boundary.position, position) >= 0) {
        this.boundaryIndex = index
        return containingScopeIds
      } else {
        for (let scopeId of boundary.closeScopeIds) {
          containingScopeIds.splice(containingScopeIds.lastIndexOf(scopeId), 1)
        }
        containingScopeIds.push(...boundary.openScopeIds)
      }
    }
    this.boundaryIndex = this.boundaries.length
    return containingScopeIds
  }

  moveToSuccessor () {
    return this.boundaryIndex++
  }

  getPosition () {
    const boundary = this.boundaries[this.boundaryIndex]
    return boundary ? boundary.position : Point.INFINITY
  }

  getCloseScopeIds () {
    const boundary = this.boundaries[this.boundaryIndex]
    return boundary ? boundary.closeScopeIds : []
  }

  getOpenScopeIds () {
    const boundary = this.boundaries[this.boundaryIndex]
    return boundary ? boundary.openScopeIds : []
  }
}
