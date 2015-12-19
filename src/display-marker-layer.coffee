{Emitter} = require 'event-kit'
DisplayMarker = require './display-marker'
Range = require './range'
Point = require './point'

module.exports =
class DisplayMarkerLayer
  constructor: (@displayLayer, @bufferMarkerLayer) ->
    @markersById = {}
    @emitter = new Emitter
    @disposable = @bufferMarkerLayer.onDidUpdate(@emitDidUpdate.bind(this))

  destroy: ->
    @bufferMarkerLayer.destroy()

  onDidUpdate: (callback) ->
    @emitter.on('did-update', callback)

  markScreenRange: (screenRange, properties) ->
    screenRange = Range.fromObject(screenRange)
    bufferRange = @displayLayer.translateScreenRange(screenRange)
    bufferMarker = @bufferMarkerLayer.markRange(bufferRange, properties)
    marker = new DisplayMarker(this, bufferMarker)
    @markersById[marker.id] = marker

  markScreenPosition: (screenPosition, properties) ->
    screenPosition = Point.fromObject(screenPosition)
    bufferPosition = @displayLayer.translateScreenPosition(screenPosition)
    bufferMarker = @bufferMarkerLayer.markPosition(bufferPosition, properties)
    marker = new DisplayMarker(this, bufferMarker)
    @markersById[marker.id] = marker

  markBufferRange: (bufferRange, properties) ->
    bufferRange = Range.fromObject(bufferRange)
    bufferMarker = @bufferMarkerLayer.markRange(bufferRange, properties)
    marker = new DisplayMarker(this, bufferMarker)
    @markersById[marker.id] = marker

  markScreenPosition: (bufferPosition, properties) ->
    bufferPosition = Point.fromObject(bufferPosition)
    bufferMarker = @bufferMarkerLayer.markPosition(bufferPosition, properties)
    marker = new DisplayMarker(this, bufferMarker)
    @markersById[marker.id] = marker

  getMarker: (id) ->
    if displayMarker = @markersById[id]
      displayMarker
    else if bufferMarker = @bufferMarkerLayer.get(id)
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
