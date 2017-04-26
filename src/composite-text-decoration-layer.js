const {CompositeDisposable, Emitter} = require('event-kit')
const {compare: comparePoints} = require('./point-helpers')
const Point = require('./point')

module.exports = class CompositeTextDecorationLayer {
  constructor (nextScopeId) {
    this.nextScopeId = nextScopeId
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

  onDidInvalidateRange (callback) {
    return this.emitter.on('did-invalidate-range', callback)
  }

  classNameForScopeId (scopeId) {
    const {layer, scopeId: layerScopeId} = this.layerScopeIdsByCompositeScopeId.get(scopeId)
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
      this.layerScopeIdsByCompositeScopeId.set(compositeScopeId, {layer, scopeId})
      this.nextScopeId += 2
    }

    return compositeScopeId
  }
}

class CompositeTextDecorationIterator {
  constructor (compositeDecorationLayer) {
    this.compositeDecorationLayer = compositeDecorationLayer
    this.iterators = []
    this.layersByIterator = new WeakMap()
    this.compositeDecorationLayer.layers.forEach((layer) => {
      const iterator = layer.buildIterator()
      this.iterators.push(iterator)
      this.layersByIterator.set(iterator, layer)
    })
  }

  seek (position) {
    let containingScopeIds = []
    for (let i = 0; i < this.iterators.length; i++) {
      const iterator = this.iterators[i]
      const layer = this.layersByIterator.get(iterator)
      const iteratorScopeIds = iterator.seek(position)
      const compositeScopeIds = iteratorScopeIds.map(id => this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, id))
      containingScopeIds = containingScopeIds.concat(compositeScopeIds)
    }

    this.iteratorsWithMinimumPosition = null
    return containingScopeIds
  }

  moveToSuccessor () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const iterator = iteratorsWithMinimumPosition[i]
      iterator.moveToSuccessor()
    }

    this.iteratorsWithMinimumPosition = null
  }

  getPosition () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    if (iteratorsWithMinimumPosition.length > 0) {
      return iteratorsWithMinimumPosition[0].getPosition()
    } else {
      return Point.INFINITY
    }
  }

  getCloseScopeIds () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    let scopeIds = []
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const iterator = iteratorsWithMinimumPosition[i]
      const layer = this.layersByIterator.get(iterator)
      const iteratorScopeIds = iterator.getCloseScopeIds()
      const compositeScopeIds = iteratorScopeIds.map(id => this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, id))
      scopeIds = scopeIds.concat(compositeScopeIds)
    }
    return scopeIds
  }

  getOpenScopeIds () {
    const iteratorsWithMinimumPosition = this.getIteratorsWithMinimumPosition()
    let scopeIds = []
    for (let i = 0; i < iteratorsWithMinimumPosition.length; i++) {
      const iterator = iteratorsWithMinimumPosition[i]
      const layer = this.layersByIterator.get(iterator)
      const iteratorScopeIds = iterator.getOpenScopeIds()
      const compositeScopeIds = iteratorScopeIds.map(id => this.compositeDecorationLayer.compositeScopeIdForLayerScopeId(layer, id))
      scopeIds = scopeIds.concat(compositeScopeIds)
    }
    return scopeIds
  }

  getIteratorsWithMinimumPosition () {
    if (this.iteratorsWithMinimumPosition == null) {
      this.iteratorsWithMinimumPosition = this.iterators.length > 0 ? [this.iterators[0]] : []
      for (let i = 1; i < this.iterators.length; i++) {
        const iterator = this.iterators[i]
        const minimumPosition = this.iteratorsWithMinimumPosition[0].getPosition()
        const comparison = comparePoints(iterator.getPosition(), minimumPosition)
        if (comparison < 0) {
          this.iteratorsWithMinimumPosition = [iterator]
        } else if (comparison === 0) {
          this.iteratorsWithMinimumPosition.push(iterator)
        }
      }
    }

    return this.iteratorsWithMinimumPosition
  }
}
