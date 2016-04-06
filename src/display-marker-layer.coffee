{Emitter} = require 'event-kit'
DisplayMarker = require './display-marker'
Range = require './range'
Point = require './point'

module.exports =
class DisplayMarkerLayer
  constructor: (@displayLayer, @bufferMarkerLayer) ->
    {@id} = @bufferMarkerLayer
    @markersById = {}
    @emitter = new Emitter
    @bufferMarkerLayer.onDidUpdate(@emitDidUpdate.bind(this))
    @bufferMarkerLayer.onDidDestroy(@emitDidDestroy.bind(this))

  destroy: ->
    @bufferMarkerLayer.destroy()

  onDidDestroy: (callback) ->
    @emitter.on('did-destroy', callback)

  onDidUpdate: (callback) ->
    @emitter.on('did-update', callback)

  onDidCreateMarker: (callback) ->
    @bufferMarkerLayer.onDidCreateMarker (bufferMarker) =>
      callback(@getMarker(bufferMarker.id))

  notifyObserversIfMarkerScreenPositionsChanged: ->
    for marker in @getMarkers()
      marker.notifyObservers(false)
    return

  markScreenRange: (screenRange, properties) ->
    screenRange = Range.fromObject(screenRange)
    bufferRange = @displayLayer.translateScreenRange(screenRange, properties)
    @createDisplayMarker(@bufferMarkerLayer.markRange(bufferRange, properties))

  markScreenPosition: (screenPosition, properties) ->
    screenPosition = Point.fromObject(screenPosition)
    bufferPosition = @displayLayer.translateScreenPosition(screenPosition, properties)
    @createDisplayMarker(@bufferMarkerLayer.markPosition(bufferPosition, properties))

  markBufferRange: (bufferRange, properties) ->
    bufferRange = Range.fromObject(bufferRange)
    @createDisplayMarker(@bufferMarkerLayer.markRange(bufferRange, properties))

  markBufferPosition: (bufferPosition, properties) ->
    bufferPosition = Point.fromObject(bufferPosition)
    @createDisplayMarker(@bufferMarkerLayer.markPosition(bufferPosition, properties))

  createDisplayMarker: (bufferMarker) ->
    displayMarker = new DisplayMarker(this, bufferMarker)
    @markersById[displayMarker.id] = displayMarker
    displayMarker

  getMarker: (id) ->
    if displayMarker = @markersById[id]
      displayMarker
    else if bufferMarker = @bufferMarkerLayer.getMarker(id)
      @markersById[id] = new DisplayMarker(this, bufferMarker)

  getMarkers: ->
    @bufferMarkerLayer.getMarkers().map ({id}) => @getMarker(id)

  getMarkerCount: ->
    @bufferMarkerLayer.getMarkerCount()

  findMarkers: (params) ->
    params = @translateToBufferMarkerLayerFindParams(params)
    @bufferMarkerLayer.findMarkers(params).map (stringMarker) => @getMarker(stringMarker.id)

  translateBufferPosition: (bufferPosition, options) ->
    @displayLayer.translateBufferPosition(bufferPosition, options)

  translateBufferRange: (bufferRange, options) ->
    @displayLayer.translateBufferRange(bufferRange, options)

  translateScreenPosition: (screenPosition, options) ->
    @displayLayer.translateScreenPosition(screenPosition, options)

  translateScreenRange: (screenRange, options) ->
    @displayLayer.translateScreenRange(screenRange, options)

  emitDidUpdate: ->
    @emitter.emit('did-update')

  emitDidDestroy: ->
    @emitter.emit('did-destroy')

  translateToBufferMarkerLayerFindParams: (params) ->
    bufferMarkerLayerFindParams = {}
    for key, value of params
      switch key
        when 'startBufferPosition'
          key = 'startPosition'
        when 'endBufferPosition'
          key = 'endPosition'
        when 'startScreenPosition'
          key = 'startPosition'
          value = @displayLayer.translateScreenPosition(value)
        when 'endScreenPosition'
          key = 'endPosition'
          value = @displayLayer.translateScreenPosition(value)
        when 'startBufferRow'
          key = 'startRow'
        when 'endBufferRow'
          key = 'endRow'
        when 'startScreenRow'
          key = 'startRow'
          value = @displayLayer.translateScreenPosition(Point(value, 0)).row
        when 'endScreenRow'
          key = 'endRow'
          value = @displayLayer.translateScreenPosition(Point(value, 0)).row
        when 'intersectsBufferRowRange'
          key = 'intersectsRowRange'
        when 'intersectsScreenRowRange'
          key = 'intersectsRowRange'
          [startScreenRow, endScreenRow] = value
          startBufferRow = @displayLayer.translateScreenPosition(Point(startScreenRow, 0)).row
          endBufferRow = @displayLayer.translateScreenPosition(Point(endScreenRow, 0)).row
          value = [startBufferRow, endBufferRow]
        when 'containsBufferRange'
          key = 'containsRange'
        when 'containsBufferPosition'
          key = 'containsPosition'
        when 'containedInBufferRange'
          key = 'containedInRange'
        when 'containedInScreenRange'
          key = 'containedInRange'
          value = @displayLayer.translateScreenRange(value)
        when 'intersectsBufferRange'
          key = 'intersectsRange'
        when 'intersectsScreenRange'
          key = 'intersectsRange'
          value = @displayLayer.translateScreenRange(value)
      bufferMarkerLayerFindParams[key] = value

    bufferMarkerLayerFindParams
