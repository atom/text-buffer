const {MarkerIndex} = require('superstring')
const {Emitter} = require('event-kit')
const Point = require('./point')
const Range = require('./range')

module.exports =
class MarkerTextDecorationLayer {
  constructor (markerLayer) {
    this.markerLayer = markerLayer
    this.classNamesByMarkerId = new Map()
    this.emitter = new Emitter()

    // this.buffer = buffer
    // this.random = random
    // this.nextMarkerId = 1
    // this.markerIndex = new MarkerIndex()
    // this.classNamesByScopeId = new Map()
    //
    // for (let value of decorations) {
    //   const className = value[0]
    //   const [rangeStart, rangeEnd] = Array.from(value[1])
    //   const markerId = this.getNextMarkerId()
    //   this.markerIndex.insert(markerId, Point.fromObject(rangeStart), Point.fromObject(rangeEnd))
    //   this.classNamesByScopeId.set(markerId, className)
    // }
    //
    // if (this.buffer) {
    //   this.buffer.registerTextDecorationLayer(this)
    // }
  }

  setClassNameForMarker (marker, className) {
    this.classNamesByMarkerId.set(marker.id, className)
  }

  classNameForScopeId (markerId) {
    return this.classNamesByMarkerId.get(markerId)
  }

  buildIterator () {
    return new MarkerTextDecorationLayerIterator(this)
  }

  getInvalidatedRanges () { return [] }

  onDidInvalidateRange (fn) {
    return this.emitter.on('did-invalidate-range', fn)
  }
  //
  // emitInvalidateRangeEvent (range) {
  //   return this.emitter.emit('did-invalidate-range', range)
  // }

  // bufferDidChange ({oldRange, newRange}) {
  //   this.invalidatedRanges = [Range.fromObject(newRange)]
  //   const {inside, overlap} = this.markerIndex.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
  //   overlap.forEach((id) => this.invalidatedRanges.push(this.markerIndex.getRange(id)))
  //   inside.forEach((id) => this.invalidatedRanges.push(this.markerIndex.getRange(id)))
  //
  //   this.insertRandomDecorations(oldRange, newRange)
  // }
}

class MarkerTextDecorationLayerIterator {
  constructor (layer) {
    this.layer = layer
  }

  seek (position) {
    const {containingStart, boundaries} = this.layer.markerLayer.index.findBoundariesIn(position, Point.INFINITY)
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
