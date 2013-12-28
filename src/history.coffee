Transaction = require './transaction'
TransactionAborted = new Error("Transaction Aborted")

module.exports =
class History
  currentTransaction: null
  transactionDepth: 0
  transactCallDepth: 0

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
      inverse = patch.invert(@textBuffer)
      @redoStack.push(inverse)
      inverse.applyTo(@textBuffer)

  redo: ->
    if patch = @redoStack.pop()
      inverse = patch.invert(@textBuffer)
      @undoStack.push(inverse)
      inverse.applyTo(@textBuffer)

  transact: (fn) ->
    @beginTransaction()
    try
      ++@transactCallDepth
      result = fn()
      --@transactCallDepth
      @commitTransaction()
      result
    catch error
      if --@transactCallDepth is 0
        @abortTransaction()
        throw error unless error is TransactionAborted
      else
        throw error

  beginTransaction: ->
    if ++@transactionDepth is 1
      @currentTransaction = new Transaction()

  commitTransaction: ->
    if --@transactionDepth is 0
      @undoStack.push(@currentTransaction) if @currentTransaction.hasBufferPatches()
      @currentTransaction = null

  abortTransaction: ->
    if @transactCallDepth is 0
      inverse = @currentTransaction.invert(@textBuffer)
      @currentTransaction = null
      @transactionDepth = 0
      inverse.applyTo(@textBuffer)
    else
      throw TransactionAborted

  isTransacting: ->
    @currentTransaction?
