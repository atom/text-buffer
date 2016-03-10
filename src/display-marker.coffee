{Emitter, CompositeDisposable} = require 'event-kit'

module.exports =
class DisplayMarker
  constructor: (@layer, @bufferMarker) ->
    {@id} = @bufferMarker
    @hasChangeObservers = false
    @emitter = new Emitter
    @disposables = null
    @destroyed = false

  destroy: ->
    @bufferMarker.destroy()
    @destroyed = true
    @emitter.emit('did-destroy')

  compare: (otherMarker) ->
    @bufferMarker.compare(otherMarker.bufferMarker)

  onDidDestroy: (callback) ->
    @emitter.on('did-destroy', callback)

  isDestroyed: -> @destroyed

  getBufferRange: ->
    @bufferMarker.getRange()

  getScreenRange: ->
    @layer.translateBufferRange(@getBufferRange())

  setBufferRange: (bufferRange, options) ->
    @bufferMarker.setRange(bufferRange, options)

  setScreenRange: (screenRange, options) ->
    @setBufferRange(@layer.translateScreenRange(screenRange, options), options)

  getHeadBufferPosition: ->
    @bufferMarker.getHeadPosition()

  setHeadBufferPosition: (bufferPosition, properties) ->
    @bufferMarker.setHeadPosition(bufferPosition, properties)

  getHeadScreenPosition: ->
    @layer.translateBufferPosition(@bufferMarker.getHeadPosition())

  setHeadScreenPosition: (screenPosition, options) ->
    bufferPosition = @layer.translateScreenPosition(screenPosition, options)
    @bufferMarker.setHeadPosition(bufferPosition, options)

  getTailBufferPosition: ->
    @bufferMarker.getTailPosition()

  setTailBufferPosition: (bufferPosition, options) ->
    @bufferMarker.setTailPosition(bufferPosition, options)

  getTailScreenPosition: ->
    @layer.translateBufferPosition(@bufferMarker.getTailPosition())

  setTailScreenPosition: (screenPosition, options) ->
    bufferPosition = @layer.translateScreenPosition(screenPosition, options)
    @bufferMarker.setTailPosition(bufferPosition, options)

  getStartBufferPosition: ->
    @bufferMarker.getStartPosition()

  getEndBufferPosition: ->
    @bufferMarker.getEndPosition()

  isValid: ->
    @bufferMarker.isValid()

  isReversed: ->
    @bufferMarker.isReversed()

  getProperties: ->
    @bufferMarker.getProperties()

  setProperties: (properties) ->
    @bufferMarker.setProperties(properties)

  hasTail: ->
    @bufferMarker.hasTail()

  plantTail: ->
    @bufferMarker.plantTail()

  clearTail: ->
    @bufferMarker.clearTail()

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
