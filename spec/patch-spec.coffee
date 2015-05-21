Point = require "../src/point"
Patch = require "../src/patch"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "iterator", ->
    iterator = null

    it "terminates after traversing to infinity when the patch is empty", ->
      iterator = patch.buildIterator()
      expect(iterator.getPosition()).toEqual(Point.zero())

      expect(iterator.next()).toEqual(value: null, done: false)
      expect(iterator.getPosition()).toEqual(Point.infinity())
      expect(iterator.getSourcePosition()).toEqual(Point.infinity())

      expect(iterator.next()).toEqual(value: null, done: true)
      expect(iterator.getPosition()).toEqual(Point.infinity())
      expect(iterator.getSourcePosition()).toEqual(Point.infinity())

    expectHunks = (hunks...) ->
      iterator.seek(Point.zero())
      for [value, position, sourcePosition] in hunks
        expect(iterator.next()).toEqual {value, done: false}
        expect(iterator.getPosition()).toEqual position
        expect(iterator.getSourcePosition()).toEqual sourcePosition
      expect(iterator.next()).toEqual {value: null, done: true}

    describe "splicing with a positive delta", ->
      beforeEach ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 4))
        iterator.splice(Point(0, 3), "abcde")

      it "inserts new content into the map", ->
        expect(iterator.getPosition()).toEqual(Point(0, 9))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["abcde", Point(0, 9), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

        iterator.seek(Point(0, 8))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expect(iterator.next()).toEqual(value: "e", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 9))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

      it "can apply a second splice that precedes the existing splice", ->
        iterator.seek(Point(0, 1))
        iterator.splice(Point(0, 2), "fgh")
        expect(iterator.getPosition()).toEqual(Point(0, 4))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 3))

        expectHunks(
          [null, Point(0, 1), Point(0, 1)]
          ["fgh", Point(0, 4), Point(0, 3)]
          [null, Point(0, 5), Point(0, 4)]
          ["abcde", Point(0, 10), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that ends at the beginning of the existing splice", ->
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 2), "fgh")
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 5))

        expectHunks(
          [null, Point(0, 2), Point(0, 2)]
          ["fghabcde", Point(0, 10), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that spans the beginning of the existing splice", ->
        iterator.seek(Point(0, 3))
        iterator.splice(Point(0, 2), "fghi")
        expect(iterator.getPosition()).toEqual(Point(0, 7))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
          [null, Point(0, 3), Point(0, 3)]
          ["fghibcde", Point(0, 11), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that starts at the beginning of the existing splice", ->
        iterator.seek(Point(0, 4))
        iterator.splice(Point(0, 2), "fghi")
        expect(iterator.getPosition()).toEqual(Point(0, 8))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["fghicde", Point(0, 11), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that is contained within the existing splice", ->
        iterator.seek(Point(0, 6))
        iterator.splice(Point(0, 2), "fghi")
        expect(iterator.getPosition()).toEqual(Point(0, 10))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["abfghie", Point(0, 11), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that encompasses the existing splice", ->
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 8), "fghijklmno")
        expect(iterator.getPosition()).toEqual(Point(0, 12))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 8))

        expectHunks(
          [null, Point(0, 2), Point(0, 2)]
          ["fghijklmno", Point(0, 12), Point(0, 8)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that ends at the end of the existing splice", ->
        iterator.seek(Point(0, 6))
        iterator.splice(Point(0, 3), "fghij")
        expect(iterator.getPosition()).toEqual(Point(0, 11))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["abfghij", Point(0, 11), Point(0, 7)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that spans the end of the existing splice", ->
        iterator.seek(Point(0, 8))
        iterator.splice(Point(0, 4), "fghijk")
        expect(iterator.getPosition()).toEqual(Point(0, 14))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 10))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["abcdfghijk", Point(0, 14), Point(0, 10)]
          [null, Point.infinity(), Point.infinity()]
        )

      it "can apply a second splice that follows the existing splice", ->
        iterator.seek(Point(0, 12))
        iterator.splice(Point(0, 3), "fghij")
        expect(iterator.getPosition()).toEqual(Point(0, 17))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 13))

        expectHunks(
          [null, Point(0, 4), Point(0, 4)]
          ["abcde", Point(0, 9), Point(0, 7)]
          [null, Point(0, 12), Point(0, 10)]
          ["fghij", Point(0, 17), Point(0, 13)]
          [null, Point.infinity(), Point.infinity()]
        )

    describe "splicing with a negative delta", ->
      iterator = null

      beforeEach ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 5), "abc")

      it "inserts new content into the map", ->
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expectHunks(
         [null, Point(0, 2), Point(0, 2)]
         ["abc", Point(0, 5), Point(0, 7)]
         [null, Point.infinity(), Point.infinity()]
        )

        iterator.seek(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        iterator.seek(Point(0, 3))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 3))

        expect(iterator.next()).toEqual(value: "bc", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

      it "can apply a second splice that is contained within the existing splice", ->
        iterator.seek(Point(0, 3))
        iterator.splice(Point(0, 1), "")
        expect(iterator.getPosition()).toEqual(Point(0, 3))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 3))

        expectHunks(
         [null, Point(0, 2), Point(0, 2)]
         ["ac", Point(0, 4), Point(0, 7)]
         [null, Point.infinity(), Point.infinity()]
        )

    describe "::seek(position)", ->
      it "stops at the first hunk that starts at or contains the given position", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 5), "")

        iterator.seek(Point.zero())
        iterator.seek(Point(0, 2))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 2))

        expect(iterator.next()).toEqual {value: "", done: false}
        expect(iterator.getPosition()).toEqual(Point(0, 2))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))
