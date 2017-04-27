const {MarkerIndex} = require('superstring')
const {Emitter} = require('event-kit')
const {compare: comparePoints, isEqual: isEqualPoint, min: minPoint} = require('../../src/point-helpers')
const Point = require('../../src/point')
const Range = require('../../src/range')

module.exports =
class TestDecorationLayer {
  constructor (decorations, buffer, random) {
    this.buffer = buffer
    this.random = random
    this.nextMarkerId = 1
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
  }

  seek (position) {
    const {containingStart, boundaries} = this.layer.markerIndex.findBoundariesIn(position, Point.INFINITY)
    this.boundaries = boundaries
    this.boundaryIndex = 0
    return containingStart
  }

  moveToSuccessor () {
    this.boundaryIndex++
  }

  getPosition () {
    const boundary = this.boundaries[this.boundaryIndex]
    return boundary ? boundary.position : Point.INFINITY
  }

  getCloseScopeIds () {
    const result = []
    const boundary = this.boundaries[this.boundaryIndex]
    if (boundary) {
      boundary.ending.forEach((markerId) => {
        if (!boundary.starting.has(markerId)) {
          result.push(markerId)
        }
      })
    }
    return result
  }

  getOpenScopeIds () {
    const result = []
    const boundary = this.boundaries[this.boundaryIndex]
    if (boundary) {
      boundary.starting.forEach((markerId) => {
        if (!boundary.ending.has(markerId)) {
          result.push(markerId)
        }
      })
    }
    return result
  }
}
