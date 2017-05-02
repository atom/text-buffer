const {Emitter} = require('event-kit')
const Point = require('./point')
const NOOP = function () {}

module.exports =
class MarkerTextDecorationLayer {
  constructor (markerLayer, {classNameForMarkerId, inlineStyleForMarkerId}) {
    this.markerLayer = markerLayer
    this.markerLayer.registerMarkerTextDecorationLayer(this)
    this.emitter = new Emitter()
    this.invalidatedRanges = []
    this.classNameForScopeId = classNameForMarkerId || NOOP
    this.inlineStyleForScopeId = inlineStyleForMarkerId || NOOP
  }

  buildIterator () {
    return new MarkerTextDecorationLayerIterator(this)
  }

  didInvalidatedMarkersInRanges (ranges) {
    this.invalidatedRanges.push(...ranges)
  }

  clearInvalidatedRanges () {
    this.invalidatedRanges = []
  }

  getInvalidatedRanges () {
    return this.invalidatedRanges
  }

  onDidInvalidateRange (fn) {
    return this.emitter.on('did-invalidate-range', fn)
  }

  didCreateMarker (range) {
    this.emitter.emit('did-invalidate-range', range)
  }

  didMoveMarker (oldRange, newRange) {
    this.didDestroyMarker(oldRange)
    this.didCreateMarker(newRange)
  }

  didDestroyMarker (range) {
    this.emitter.emit('did-invalidate-range', range)
  }
}

class MarkerTextDecorationLayerIterator {
  constructor (layer) {
    this.layer = layer
  }

  seek (position) {
    const {containingStart, boundaries} = this.layer.markerLayer.index.findBoundariesIn(position, Point.INFINITY)
    this.boundaries = boundaries
    for (let i = 0; i < containingStart.length; i++) {
      const marker = this.layer.markerLayer.getMarker(containingStart[i])
      if (!marker.isValid()) {
        containingStart.splice(i, 1)
        i--
      }
    }
    this.boundaryIndex = 0
    return containingStart
  }

  moveToSuccessor () {
    this.boundaryIndex++
  }

  getPosition () {
    const boundary = this.boundaries[this.boundaryIndex]
    return boundary ? Point.fromObject(boundary.position) : Point.INFINITY
  }

  getCloseScopeIds () {
    const result = []
    const boundary = this.boundaries[this.boundaryIndex]
    if (boundary) {
      boundary.ending.forEach((markerId) => {
        const marker = this.layer.markerLayer.getMarker(markerId)
        if (!boundary.starting.has(markerId) && marker.isValid()) {
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
        const marker = this.layer.markerLayer.getMarker(markerId)
        if (!boundary.ending.has(markerId) && marker.isValid()) {
          result.push(markerId)
        }
      })
    }
    return result
  }
}
