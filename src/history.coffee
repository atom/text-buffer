Transaction = require './transaction'

module.exports =
class History
  currentTransaction: null

  constructor: (@textBuffer) ->
    @undoStack = []
    @redoStack = []

  recordNewPatch: (patch) ->
    if @currentTransaction?
      @currentTransaction.push(patch)
    else
      @undoStack.push(patch)
    @redoStack.length = 0

  undo: ->
    if @currentTransaction?
      @abortTransaction()
    else if patch = @undoStack.pop()
      inverse = patch.invert()
      @redoStack.push(inverse)
      inverse.applyTo(@textBuffer)

  redo: ->
    if patch = @redoStack.pop()
      inverse = patch.invert()
      @undoStack.push(inverse)
      inverse.applyTo(@textBuffer)

  beginTransaction: ->
    @currentTransaction = new Transaction()

  commitTransaction: ->
    @undoStack.push(@currentTransaction)
    @currentTransaction = null

  abortTransaction: ->
    inverse = @currentTransaction.invert()
    @currentTransaction = null
    inverse.applyTo(@textBuffer)
