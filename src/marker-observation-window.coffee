{CompositeDisposable} = require 'event-kit'
Range = require './range'

EMPTY = new Set
EMPTY.add = null
EMPTY.clear = null
EMPTY.delete = null
Object.freeze(EMPTY)

module.exports =
class MarkerObservationWindow
  constructor: (@markerStore, @callback) ->
    @ids = new Set
    @disposables = new CompositeDisposable

  setRange: (range) ->
    @range = Range.fromObject(range)
    @updateAll()

  updateAll: ->
    return unless @range?

    insertedIds = new Set
    updatedIds = new Set
    removedIds = new Set(@ids)
    @ids = @markerStore.index.findIntersecting(@range.start, @range.end)

    @ids.forEach (id) =>
      if removedIds.delete(id)
        updatedIds.add(id)
      else
        insertedIds.add(id)

    if insertedIds.size > 0 or updatedIds.size > 0 or removedIds.size > 0
      @callback(insert: insertedIds, update: updatedIds, remove: removedIds)

  update: (id, range) ->
    return unless @range?
    if @ids.has(id)
      if range.intersectsWith(@range)
        @callback(
          insert: EMPTY
          update: new Set().add(id)
          remove: EMPTY
        )
      else
        @ids.delete(id)
        @callback(
          insert: EMPTY
          update: EMPTY
          remove: new Set().add(id)
        )
    else
      if range.intersectsWith(@range)
        @ids.add(id)
        @callback(
          insert: new Set().add(id)
          update: EMPTY
          remove: EMPTY
        )

  destroy: ->
    @destroyed = true
    @markerStore.removeMarkerObservationWindow(this)
