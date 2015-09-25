{clone} = require "underscore-plus"
MarkerIndex = require "marker-index"
Point = require "./point"
Range = require "./range"
Marker = require "./marker"
{intersectSet} = require "./set-helpers"

SerializationVersion = 2

module.exports =
class MarkerStore
  @deserialize: (delegate, state) ->
    store = new MarkerStore(delegate)
    store.deserialize(state)
    store

  @serializeSnapshot: (snapshot) ->
    result = {}
    for id, markerSnapshot of snapshot
      result[id] = clone(markerSnapshot)
      result[id].range = markerSnapshot.range.serialize()
    result

  @deserializeSnapshot: (snapshot) ->
    result = {}
    for id, markerSnapshot of snapshot
      result[id] = clone(markerSnapshot)
      result[id].range = Range.deserialize(markerSnapshot.range)
    result

  constructor: (@delegate) ->
    @index = new MarkerIndex
    @markersById = {}
    @historiedMarkers = new Set
    @nextMarkerId = 0

  ###
  Section: TextBuffer API
  ###

  getMarker: (id) ->
    @markersById[id]

  getMarkers: ->
    marker for id, marker of @markersById

  getMarkerCount: ->
    Object.keys(@markersById).length

  findMarkers: (params) ->
    markerIds = null

    for key in Object.keys(params)
      value = params[key]
      switch key
        when 'startPosition'
          index = @delegate.characterIndexForPosition(value)
          markerIds = filterSet(markerIds, @index.findStartingAt(index))
        when 'endPosition'
          index = @delegate.characterIndexForPosition(value)
          markerIds = filterSet(markerIds, @index.findEndingAt(index))
        when 'containsPoint', 'containsPosition'
          index = @delegate.characterIndexForPosition(value)
          markerIds = filterSet(markerIds, @index.findContaining(index))
        when 'containsRange'
          {start, end} = Range.fromObject(value)
          startIndex = @delegate.characterIndexForPosition(start)
          endIndex = @delegate.characterIndexForPosition(end)
          markerIds = filterSet(markerIds, @index.findContaining(startIndex, endIndex))
        when 'intersectsRange'
          {start, end} = Range.fromObject(value)
          startIndex = @delegate.characterIndexForPosition(start)
          endIndex = @delegate.characterIndexForPosition(end)
          markerIds = filterSet(markerIds, @index.findIntersecting(startIndex, endIndex))
        when 'startRow'
          startIndex = @delegate.characterIndexForPosition(Point(value, 0))
          endIndex = @delegate.characterIndexForPosition(Point(value, Infinity))
          markerIds = filterSet(markerIds, @index.findStartingIn(startIndex, endIndex))
        when 'endRow'
          startIndex = @delegate.characterIndexForPosition(Point(value, 0))
          endIndex = @delegate.characterIndexForPosition(Point(value, Infinity))
          markerIds = filterSet(markerIds, @index.findEndingIn(startIndex, endIndex))
        when 'intersectsRow'
          startIndex = @delegate.characterIndexForPosition(Point(value, 0))
          endIndex = @delegate.characterIndexForPosition(Point(value, Infinity))
          markerIds = filterSet(markerIds, @index.findIntersecting(startIndex, endIndex))
        when 'intersectsRowRange'
          startIndex = @delegate.characterIndexForPosition(Point(value[0], 0))
          endIndex = @delegate.characterIndexForPosition(Point(value[1], Infinity))
          markerIds = filterSet(markerIds, @index.findIntersecting(startIndex, endIndex))
        when 'containedInRange'
          {start, end} = Range.fromObject(value)
          startIndex = @delegate.characterIndexForPosition(start)
          endIndex = @delegate.characterIndexForPosition(end)
          markerIds = filterSet(markerIds, @index.findContainedIn(startIndex, endIndex))
        else
          continue
      delete params[key]

    markerIds ?= new Set(Object.keys(@markersById))

    result = []
    markerIds.forEach (id) =>
      marker = @markersById[id]
      result.push(marker) if marker.matchesParams(params)
    result.sort (a, b) -> a.compare(b)

  markRange: (range, options={}) ->
    @createMarker(Range.fromObject(range), Marker.extractParams(options))

  markPosition: (position, options={}) ->
    options.tailed ?= false
    @markRange(Range(position, position), options)

  splice: (startPoint, oldExtentPoint, newExtentPoint) ->
    startIndex = @delegate.characterIndexForPosition(startPoint)
    oldEndIndex = @delegate.characterIndexForPosition(startPoint.traverse(oldExtentPoint))
    newEndIndex = @delegate.characterIndexForPosition(startPoint.traverse(newExtentPoint))
    oldExtent = oldEndIndex - startIndex
    newExtent = newEndIndex - startIndex

    intersecting = @index.findIntersecting(startIndex, oldEndIndex)
    endingAt = @index.findEndingAt(startIndex)
    startingAt = @index.findStartingAt(oldEndIndex)
    startingIn = @index.findStartingIn(startIndex + 1, oldEndIndex - 1)
    endingIn = @index.findEndingIn(startIndex + 1, oldEndIndex - 1)

    for id in Object.keys(@markersById)
      marker = @markersById[id]
      switch marker.getInvalidationStrategy()
        when 'touch'
          invalid = intersecting.has(id)
        when 'inside'
          invalid = intersecting.has(id) and not (startingAt.has(id) or endingAt.has(id))
        when 'overlap'
          invalid = startingIn.has(id) or endingIn.has(id)
        when 'surround'
          invalid = startingIn.has(id) and endingIn.has(id)
        when 'never'
          invalid = false
      marker.valid = false if invalid

    @index.splice(startIndex, oldExtent, newExtent)

  restoreFromSnapshot: (snapshots) ->
    return unless snapshots?

    createdIds = new Set
    snapshotIds = Object.keys(snapshots)
    existingMarkerIds = Object.keys(@markersById)

    for id in snapshotIds
      snapshot = snapshots[id]
      if marker = @markersById[id]
        marker.update(marker.getRange(), snapshot, true)
      else
        newMarker = @createMarker(snapshot.range, snapshot)
        createdIds.add(newMarker.id)

    for id in existingMarkerIds
      if (marker = @markersById[id]) and (not snapshots[id]?)
        if @historiedMarkers.has(id)
          marker.destroy()
        else
          marker.emitChangeEvent(marker.getRange(), true, false)

    @delegate.markersUpdated()
    return

  createSnapshot: (emitChangeEvents=false) ->
    result = {}
    ranges = @dumpMarkerRanges(@historiedMarkers)
    for id in Object.keys(@markersById)
      if marker = @markersById[id]
        if marker.maintainHistory
          result[id] = marker.getSnapshot(ranges[id], false)
        if emitChangeEvents
          marker.emitChangeEvent(ranges[id], true, false)
    @delegate.markersUpdated() if emitChangeEvents
    result

  serialize: ->
    ranges = @dumpMarkerRanges()
    markersById = {}
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      markersById[id] = marker.getSnapshot(ranges[id], false) if marker.persistent
    {@nextMarkerId, markersById, version: SerializationVersion}

  dumpMarkerRanges: (filterSet) ->
    ranges = @index.dump(filterSet)
    for markerId, indexRange of ranges
      startPosition = @delegate.positionForCharacterIndex(indexRange.start)
      endPosition = @delegate.positionForCharacterIndex(indexRange.end)
      ranges[markerId] = new Range(startPosition, endPosition)
    ranges

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @nextMarkerId = state.nextMarkerId
    for id, markerState of state.markersById
      range = Range.fromObject(markerState.range)
      delete markerState.range
      @addMarker(id, range, markerState)
    return

  ###
  Section: Marker interface
  ###

  markerUpdated: ->
    @delegate.markersUpdated()

  destroyMarker: (id) ->
    delete @markersById[id]
    @historiedMarkers.delete(id)
    @index.delete(id)
    @delegate.markersUpdated()

  getMarkerRange: (id) ->
    [startIndex, endIndex] = @index.getRange(id)
    new Range(@delegate.positionForCharacterIndex(startIndex), @delegate.positionForCharacterIndex(endIndex))

  getMarkerStartPosition: (id) ->
    @delegate.positionForCharacterIndex(@index.getStart(id))

  getMarkerEndPosition: (id) ->
    @delegate.positionForCharacterIndex(@index.getEnd(id))

  setMarkerRange: (id, range) ->
    {start, end} = Range.fromObject(range)
    startIndex = @delegate.characterIndexForPosition(@delegate.clipPosition(start))
    endIndex = @delegate.characterIndexForPosition(@delegate.clipPosition(end))
    @index.delete(id)
    @index.insert(id, startIndex, endIndex)

  setMarkerHasTail: (id, hasTail) ->
    @index.setExclusive(id, not hasTail)

  createMarker: (range, params) ->
    id = String(@nextMarkerId++)
    marker = @addMarker(id, range, params)
    @delegate.markerCreated(marker)
    @delegate.markersUpdated()
    marker

  ###
  Section: Private
  ###

  addMarker: (id, range, params) ->
    Point.assertValid(range.start)
    Point.assertValid(range.end)
    startIndex = @delegate.characterIndexForPosition(range.start)
    endIndex = @delegate.characterIndexForPosition(range.end)
    marker = new Marker(id, this, range, params)
    @markersById[id] = marker
    @index.insert(id, startIndex, endIndex)
    if marker.getInvalidationStrategy() is 'inside'
      @index.setExclusive(id, true)
    if marker.maintainHistory
      @historiedMarkers.add(id)
    marker

filterSet = (set1, set2) ->
  if set1
    intersectSet(set1, set2)
    set1
  else
    set2
