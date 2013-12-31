TextBuffer = require '../src/text-buffer'

describe "TextBuffer", ->
  buffer = null

  describe "construction", ->
    it "can be constructed empty", ->
      buffer = new TextBuffer
      expect(buffer.getLineCount()).toBe 1
      expect(buffer.getText()).toBe ''
      expect(buffer.lineForRow(0)).toBe ''
      expect(buffer.lineEndingForRow(0)).toBe ''

    it "can be constructed with initial text", ->
      text = "hello\nworld\r\nhow are you doing?"
      buffer = new TextBuffer({text})
      expect(buffer.getLineCount()).toBe 3
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'hello'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe 'world'
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'
      expect(buffer.lineForRow(2)).toBe 'how are you doing?'
      expect(buffer.lineEndingForRow(2)).toBe ''

  describe "::setTextInRange(range, text)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")

    it "can replace text on a single line with a standard newline", ->
      buffer.setTextInRange([[0, 2], [0, 4]], "y y")
      expect(buffer.getText()).toEqual "hey yo\nworld\r\nhow are you doing?"

    it "can replace text on a single line with a carriage-return/newline", ->
      buffer.setTextInRange([[1, 3], [1, 5]], "ms")
      expect(buffer.getText()).toEqual "hello\nworms\r\nhow are you doing?"

    it "can replace text in a region spanning multiple lines, ending on the last line", ->
      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat")
      expect(buffer.getText()).toEqual "hey there\r\ncat\nwhat are you doing?"

    it "can replace text in a region spanning multiple lines, ending with a carriage-return/newline", ->
      buffer.setTextInRange([[0, 2], [1, 3]], "y\nyou're o")
      expect(buffer.getText()).toEqual "hey\nyou're old\r\nhow are you doing?"

    it "emits a 'changed' event with the relevant details after a change", ->
      changes = []
      buffer.on 'changed', (change) -> changes.push(change)
      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat")
      expect(changes).toEqual [{
        oldRange: [[0, 2], [2, 3]]
        newRange: [[0, 2], [2, 4]]
        oldText: "llo\nworld\r\nhow"
        newText: "y there\r\ncat\nwhat"
      }]

    it "returns the newRange of the change", ->
      expect(buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat")).toEqual [[0, 2], [2, 4]]

  describe "::undo() and ::redo()", ->
    beforeEach ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")

    it "undoes and redoes multiple changes", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

    it "clears the redo stack upon a fresh change", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.setTextInRange([[1, 3], [1, 5]], "m")
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

  describe "transactions", ->
    beforeEach ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")

    describe "::beginTransaction()", ->
      beforeEach ->
        buffer.setTextInRange([[1, 3], [1, 5]], 'ms')
        buffer.beginTransaction()

      describe "when followed by ::commitTransaction()", ->
        it "groups all operations since the beginning of the transaction into a single undo operation", ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")
          buffer.commitTransaction()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

          # subsequent changes are not included in the transaction
          buffer.setTextInRange([[1, 0], [1, 0]], "little ")
          buffer.undo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

          # this should undo all changes in the transaction
          buffer.undo()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

          # previous changes are not included in the transaction
          buffer.undo()
          expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"
          buffer.redo()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

          # this should redo all changes in the transaction
          buffer.redo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

          # this should redo the change following the transaction
          buffer.redo()
          expect(buffer.getText()).toBe "hey\nlittle worms\r\nhow are you digging?"

        it "does not push the transaction to the undo stack if it is empty", ->
          buffer.commitTransaction()
          buffer.undo()
          expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      describe "when followed by ::abortTransaction()", ->
        it "undoes all operations since the beginning of the transaction", ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")
          buffer.abortTransaction()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

          buffer.undo()
          expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

          buffer.redo()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

          buffer.redo()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

      describe "when followed by ::undo()", ->
        it "aborts the transaction", ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")
          buffer.undo()
          expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

      it "still clears the redo stack when adding to a transaction", ->
        buffer.abortTransaction()
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.beginTransaction()
        buffer.setTextInRange([[0, 0], [0, 5]], "hey")
        buffer.abortTransaction()

        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"
        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "combines nested transactions", ->
        buffer.setTextInRange([[0, 2], [0, 5]], "y")
        buffer.beginTransaction()
        buffer.setTextInRange([[2, 13], [2, 14]], "igg")
        buffer.commitTransaction()
        buffer.commitTransaction()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

    describe "::transact(fn)", ->
      it "groups all operations in the given function in a single transaction", ->
        buffer.setTextInRange([[1, 3], [1, 5]], 'ms')
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")

        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "halts execution of the function if the transaction is aborted", ->
        innerContinued = false
        outerContinued = false

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")
            buffer.abortTransaction()
            innerContinued = true
          outerContinued = true

        expect(innerContinued).toBe false
        expect(outerContinued).toBe false
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

  describe "::getTextInRange(range)", ->
    it "returns the text in a given range", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.getTextInRange([[1, 1], [1, 4]])).toBe "orl"
      expect(buffer.getTextInRange([[0, 3], [2, 3]])).toBe "lo\nworld\r\nhow"
      expect(buffer.getTextInRange([[0, 0], [2, 18]])).toBe buffer.getText()

  describe "::clipPosition(position)", ->
    it "returns a valid position closest to the given position", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.clipPosition([-1, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([-1, 2])).toEqual [0, 0]
      expect(buffer.clipPosition([0, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([0, 20])).toEqual [0, 5]
      expect(buffer.clipPosition([1, -1])).toEqual [1, 0]
      expect(buffer.clipPosition([1, 20])).toEqual [1, 5]
      expect(buffer.clipPosition([10, 0])).toEqual [2, 18]
      expect(buffer.clipPosition([Infinity, 0])).toEqual [2, 18]

  describe "::characterIndexForPosition(position)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the absolute character offset for the given position", ->
      expect(buffer.characterIndexForPosition([0, 0])).toBe 0
      expect(buffer.characterIndexForPosition([0, 1])).toBe 1
      expect(buffer.characterIndexForPosition([0, 4])).toBe 4
      expect(buffer.characterIndexForPosition([1, 0])).toBe 5
      expect(buffer.characterIndexForPosition([1, 1])).toBe 6
      expect(buffer.characterIndexForPosition([1, 3])).toBe 8
      expect(buffer.characterIndexForPosition([2, 0])).toBe 10
      expect(buffer.characterIndexForPosition([2, 1])).toBe 11
      expect(buffer.characterIndexForPosition([3, 0])).toBe 14
      expect(buffer.characterIndexForPosition([3, 5])).toBe 19

    it "throws an exception if the position is out of bounds", ->
      expect(-> buffer.characterIndexForPosition([-1, 0])).toThrow()
      expect(-> buffer.characterIndexForPosition([0, -1])).toThrow()
      expect(-> buffer.characterIndexForPosition([0, 5])).toThrow()
      expect(-> buffer.characterIndexForPosition([4, 0])).toThrow()

  describe "::positionForCharacterIndex(offset)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the position for the given absolute character offset", ->
      expect(buffer.positionForCharacterIndex(0)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(1)).toEqual [0, 1]
      expect(buffer.positionForCharacterIndex(4)).toEqual [0, 4]
      expect(buffer.positionForCharacterIndex(5)).toEqual [1, 0]
      expect(buffer.positionForCharacterIndex(6)).toEqual [1, 1]
      expect(buffer.positionForCharacterIndex(8)).toEqual [1, 3]
      expect(buffer.positionForCharacterIndex(10)).toEqual [2, 0]
      expect(buffer.positionForCharacterIndex(11)).toEqual [2, 1]
      expect(buffer.positionForCharacterIndex(14)).toEqual [3, 0]
      expect(buffer.positionForCharacterIndex(19)).toEqual [3, 5]

    it "throws an exception if the offset is out of bounds", ->
      expect(-> buffer.positionForCharacterIndex(-1)).toThrow()
      expect(-> buffer.positionForCharacterIndex(20)).toThrow()

  describe "serialization", ->
    it "can serialize / deserialize the buffer along with its history and markers", ->
      bufferA = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      bufferA.setTextInRange([[0, 5], [0, 5]], " there")
      bufferA.transact -> bufferA.setTextInRange([[1, 0], [1, 5]], "friend")
      marker1A = bufferA.markRange([[0, 1], [1, 2]], reversed: true, foo: 1)
      marker2A = bufferA.markPosition([2, 2], bar: 2)

      bufferB = TextBuffer.deserialize(bufferA.serialize())

      expect(bufferB.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      marker1B = bufferB.getMarker(marker1A.id)
      marker2B = bufferB.getMarker(marker2A.id)
      expect(marker1B.getRange()).toEqual [[0, 1], [1, 2]]
      expect(marker1B.isReversed()).toBe true
      expect(marker1B.getProperties()).toEqual {foo: 1}
      expect(marker2B.getHeadPosition()).toEqual [2, 2]
      expect(marker2B.hasTail()).toBe false
      expect(marker2B.getProperties()).toEqual {bar: 2}

      bufferB.undo()
      bufferB.undo()
      expect(bufferB.getText()).toBe "hello\nworld\r\nhow are you doing?"
