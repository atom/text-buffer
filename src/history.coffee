Transaction = require './transaction'

module.exports =
class History
  currentTransaction: null
  transactionDepth: 0

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
    if ++@transactionDepth is 1
      @currentTransaction = new Transaction()

  commitTransaction: ->
    if --@transactionDepth is 0
      @undoStack.push(@currentTransaction) if @currentTransaction.patches.length > 0
      @currentTransaction = null

  abortTransaction: ->
    inverse = @currentTransaction.invert()
    @currentTransaction = null
    @transactionDepth = 0
    inverse.applyTo(@textBuffer)
