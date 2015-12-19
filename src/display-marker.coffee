{Emitter, CompositeDisposable} = require 'event-kit'

module.exports =
class DisplayMarker
  constructor: (@displayMarkerLayer, @bufferMarker) ->
    {@id} = @bufferMarker
    @hasChangeObservers = false
    @emitter = new Emitter
    @disposables = null

  destroy: ->
    @bufferMarker.destroy()
    @emitter.emit('did-destroy')

  onDidDestroy: (callback) ->
    @emitter.on('did-destroy', callback)

  getBufferRange: ->
    @bufferMarker.getRange()

  getScreenRange: ->
    @displayMarkerLayer.translateBufferRange(@getBufferRange())

  setBufferRange: (bufferRange, properties) ->
    @bufferMarker.setRange(bufferRange, properties)

  setScreenRange: (screenRange, properties) ->
    @setBufferRange(@displayMarkerLayer.translateScreenRange(screenRange), properties)

  getHeadBufferPosition: ->
    @bufferMarker.getHeadPosition()

  getHeadScreenPosition: ->
    @displayMarkerLayer.translateBufferPosition(@bufferMarker.getHeadPosition())

  getTailBufferPosition: ->
    @bufferMarker.getTailPosition()

  getTailScreenPosition: ->
    @displayMarkerLayer.translateBufferPosition(@bufferMarker.getTailPosition())

  isValid: ->
    @bufferMarker.isValid()

  onDidChange: (callback) ->
    unless @hasChangeObservers
      @emitter = new Emitter
      @disposables = new CompositeDisposable
      @oldHeadBufferPosition = @getHeadBufferPosition()
      @oldHeadScreenPosition = @getHeadScreenPosition()
      @oldTailBufferPosition = @getTailBufferPosition()
      @oldTailScreenPosition = @getTailScreenPosition()
      @wasValid = @isValid()
      @disposables.add @bufferMarker.onDidChange (event) => @notifyObservers(event.textChanged)
      @hasChangeObservers = true
    @emitter.on 'did-change', callback

  notifyObservers: (textChanged) ->
    textChanged ?= false

    newHeadBufferPosition = @getHeadBufferPosition()
    newHeadScreenPosition = @getHeadScreenPosition()
    newTailBufferPosition = @getTailBufferPosition()
    newTailScreenPosition = @getTailScreenPosition()
    isValid = @isValid()

    return if isValid is @wasValid and
      newHeadBufferPosition.isEqual(@oldHeadBufferPosition) and
      newHeadScreenPosition.isEqual(@oldHeadScreenPosition) and
      newTailBufferPosition.isEqual(@oldTailBufferPosition) and
      newTailScreenPosition.isEqual(@oldTailScreenPosition)

    changeEvent = {
      @oldHeadScreenPosition, newHeadScreenPosition,
      @oldTailScreenPosition, newTailScreenPosition,
      @oldHeadBufferPosition, newHeadBufferPosition,
      @oldTailBufferPosition, newTailBufferPosition,
      textChanged,
      @wasValid,
      isValid
    }

    @oldHeadBufferPosition = newHeadBufferPosition
    @oldHeadScreenPosition = newHeadScreenPosition
    @oldTailBufferPosition = newTailBufferPosition
    @oldTailScreenPosition = newTailScreenPosition
    @wasValid = isValid

    @emitter.emit 'did-change', changeEvent
