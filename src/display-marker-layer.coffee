{Emitter} = require 'event-kit'
DisplayMarker = require './display-marker'

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

  markScreenRange: (screenRange) ->
    marker = new DisplayMarker(this, @bufferMarkerLayer.markRange(@displayLayer.translateScreenRange(screenRange)))
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
