const {CompositeDisposable, Emitter} = require('event-kit')
const {compare: comparePoints} = require('./point-helpers')
const Point = require('./point')

module.exports = class CompositeTextDecorationLayer {
  constructor (nextScopeId) {
    this.nextScopeId = nextScopeId
    this.layersByCompositeScopeId = new Map()
    this.layerScopeIdsByCompositeScopeId = new Map()
    this.compositeScopeIdsByLayerAndScopeId = new Map()
    this.layers = new Set()
    this.emitter = new Emitter()
    this.disposables = new CompositeDisposable()
    this.didInvalidateRangeDisposablesByLayer = new Map()
  }

  dispose () {
    this.disposables.dispose()
    this.didInvalidateRangeDisposablesByLayer.clear()
    this.layersByCompositeScopeId.clear()
    this.layerScopeIdsByCompositeScopeId.clear()
    this.compositeScopeIdsByLayerAndScopeId.clear()
    this.layers.clear()
  }

  buildIterator () {
    return new CompositeTextDecorationIterator(this)
  }

  addLayer (layer) {
    this.layers.add(layer)
    if (typeof layer.onDidInvalidateRange === 'function') {
      const disposable = layer.onDidInvalidateRange((range) => {
        this.emitter.emit('did-invalidate-range', range)
      })
      this.disposables.add(disposable)
      this.didInvalidateRangeDisposablesByLayer.set(layer, disposable)
    }
  }

  removeLayer (layer) {
    const didInvalidateRangeDisposable = this.didInvalidateRangeDisposablesByLayer.get(layer)
    if (didInvalidateRangeDisposable) {
      didInvalidateRangeDisposable.dispose()
      this.didInvalidateRangeDisposablesByLayer.delete(layer)
    }

    const compositeScopeIdsByLayerScopeId = this.compositeScopeIdsByLayerAndScopeId.get(layer)
    if (compositeScopeIdsByLayerScopeId) {
      compositeScopeIdsByLayerScopeId.forEach((compositeScopeId) => {
        this.layerScopeIdsByCompositeScopeId.delete(compositeScopeId)
      })
      this.layersByCompositeScopeId.delete(layer)
      this.compositeScopeIdsByLayerAndScopeId.delete(layer)
    }

    this.layers.delete(layer)
  }

  getLayers () {
    return Array.from(this.layers)
  }

  getInvalidatedRanges () {
    let invalidatedRanges = []
    this.layers.forEach((layer) => {
      invalidatedRanges = invalidatedRanges.concat(layer.getInvalidatedRanges())
    })
    return invalidatedRanges
  }

  clearInvalidatedRanges () {
    this.layers.forEach((layer) => { layer.getInvalidatedRanges() })
  }

  onDidInvalidateRange (callback) {
    return this.emitter.on('did-invalidate-range', callback)
  }

  classNameForScopeId (scopeId) {
    const layer = this.layersByCompositeScopeId.get(scopeId)
    const layerScopeId = this.layerScopeIdsByCompositeScopeId.get(scopeId)
    return layer.classNameForScopeId(layerScopeId)
  }

  compositeScopeIdForLayerScopeId (layer, scopeId) {
    let compositeScopeIdsByLayerScopeId = this.compositeScopeIdsByLayerAndScopeId.get(layer)
    if (compositeScopeIdsByLayerScopeId == null) {
      compositeScopeIdsByLayerScopeId = new Map()
      this.compositeScopeIdsByLayerAndScopeId.set(layer, compositeScopeIdsByLayerScopeId)
    }

    let compositeScopeId = compositeScopeIdsByLayerScopeId.get(scopeId)
    if (compositeScopeId == null) {
      compositeScopeId = this.nextScopeId
      compositeScopeIdsByLayerScopeId.set(scopeId, compositeScopeId)
      this.layersByCompositeScopeId.set(compositeScopeId, layer)
      this.layerScopeIdsByCompositeScopeId.set(compositeScopeId, scopeId)
      this.nextScopeId += 2
    }

    return compositeScopeId
  }
}

class CompositeTextDecorationIterator {
  constructor (compositeDecorationLayer) {
    this.compositeDecorationLayer = compositeDecorationLayer
    this.iterators = []
    this.iteratorsWithMinimumPosition = []
    this.compositeDecorationLayer.layers.forEach((layer) => {
      const iterator = layer.buildIterator()
      this.iterators.push({iterator, layer})
    })
  }

  seek (position) {
    let containingScopeIds = []
    for (let i = 0; i < this.iterators.length; i++) {
      const {iterator, layer} = this.iterators[i]
      const iteratorScopeIds = iterator.seek(position)
      for (let j = 0; j < iteratorScopeIds.length; j++) {
        const compositeScopeId = this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, iteratorScopeIds[j])
        containingScopeIds.push(compositeScopeId)
      }
    }

    this.iteratorsWithMinimumPosition.length = 0
    return containingScopeIds
  }

  moveToSuccessor () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const {iterator} = iteratorsWithMinimumPosition[i]
      iterator.moveToSuccessor()
    }

    this.iteratorsWithMinimumPosition.length = 0
  }

  getPosition () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    if (iteratorsWithMinimumPosition.length > 0) {
      const {iterator} = iteratorsWithMinimumPosition[0]
      return iterator.getPosition()
    } else {
      return Point.INFINITY
    }
  }

  getCloseScopeIds () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    let scopeIds = []
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const {iterator, layer} = iteratorsWithMinimumPosition[i]
      const iteratorScopeIds = iterator.getCloseScopeIds()
      for (let j = 0; j < iteratorScopeIds.length; j++) {
        const compositeScopeId = this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, iteratorScopeIds[j])
        scopeIds.push(compositeScopeId)
      }
    }
    return scopeIds
  }

  getOpenScopeIds () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    let scopeIds = []
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const {iterator, layer} = iteratorsWithMinimumPosition[i]
      const iteratorScopeIds = iterator.getOpenScopeIds()
      for (let j = 0; j < iteratorScopeIds.length; j++) {
        const compositeScopeId = this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, iteratorScopeIds[j])
        scopeIds.push(compositeScopeId)
      }
    }
    return scopeIds
  }

  getIteratorsWithMinimumPosition () {
    if (this.iterators.length <= 1) {
      return this.iterators
    } else if (this.iteratorsWithMinimumPosition.length === 0) {
      this.iteratorsWithMinimumPosition.push(this.iterators[0])
      for (let i = 1; i < this.iterators.length; i++) {
        const {iterator} = this.iterators[i]
        const minimumPosition = this.iteratorsWithMinimumPosition[0].iterator.getPosition()
        const comparison = comparePoints(iterator.getPosition(), minimumPosition)
        if (comparison < 0) {
          this.iteratorsWithMinimumPosition.length = 1
          this.iteratorsWithMinimumPosition[0] = this.iterators[i]
        } else if (comparison === 0) {
          this.iteratorsWithMinimumPosition.push(this.iterators[i])
        }
      }
    }

    return this.iteratorsWithMinimumPosition
  }
}
