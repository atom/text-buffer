Point = require "../src/point"
Patch = require "../src/patch"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "::splice(outputPosition, oldOutputExtent, newOutputExtent, content)", ->
    it "can insert disjoint changes", ->
      patch.splice(Point(0, 5), Point(0, 3), Point(0, 4), "abcd")
      patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
      patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 4)
          content: "abcd"
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 4)
          outputExtent: Point(0, 3)
          content: "efg"
        }
        {
          inputExtent: Point(0, 1)
          outputExtent: Point(0, 1)
          content: null
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 2)
          content: "hi"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

    it "can insert a change within a change", ->
      patch.splice(Point(0, 3), Point(0, 5), Point(0, 8), "abcdefgh")
      patch.splice(Point(0, 4), Point(0, 2), Point(0, 3), "ijk")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 9)
          content: "aijkdefgh"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

      patch.splice(Point(0, 4), Point(0, 3), Point(0, 1), "l")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 7)
          content: "aldefgh"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

    it "can insert a change that overlaps the end of an existing change", ->
      patch.splice(Point(0, 5), Point(0, 3), Point(0, 4), "abcd")
      patch.splice(Point(0, 8), Point(0, 4), Point(0, 5), "efghi")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 6)
          outputExtent: Point(0, 8)
          content: "abcefghi"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

      patch.splice(Point(0, 9), Point(0, 6), Point(0, 3), "jkl")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 8)
          outputExtent: Point(0, 7)
          content: "abcejkl"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

  describe "::buildIterator()", ->
    beforeEach ->
      patch.splice(Point(0, 5), Point(0, 2), Point(0, 4), "abcd")
      patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
      patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")

    describe "::next()", ->
      it "returns the current hunk's contents and advances to the next hunk", ->
        iterator = patch.buildIterator()
        expect(iterator.getPosition()).toEqual Point(0, 0)
        expect(iterator.getSourcePosition()).toEqual Point(0, 0)

        expect(iterator.next()).toEqual {value: null, done: false}
        expect(iterator.getPosition()).toEqual Point(0, 5)
        expect(iterator.getSourcePosition()).toEqual Point(0, 5)

        expect(iterator.next()).toEqual {value: "abcd", done: false}
        expect(iterator.getPosition()).toEqual Point(0, 9)
        expect(iterator.getSourcePosition()).toEqual Point(0, 7)

        expect(iterator.next()).toEqual {value: null, done: false}
        expect(iterator.getPosition()).toEqual Point(0, 12)
        expect(iterator.getSourcePosition()).toEqual Point(0, 10)

        expect(iterator.next()).toEqual {value: "efg", done: false}
        expect(iterator.getPosition()).toEqual Point(0, 15)
        expect(iterator.getSourcePosition()).toEqual Point(0, 14)

        expect(iterator.next()).toEqual {value: null, done: false}
        expect(iterator.getPosition()).toEqual Point(0, 16)
        expect(iterator.getSourcePosition()).toEqual Point(0, 15)

        expect(iterator.next()).toEqual {value: "hi", done: false}
        expect(iterator.getPosition()).toEqual Point(0, 18)
        expect(iterator.getSourcePosition()).toEqual Point(0, 18)

        expect(iterator.next()).toEqual {value: null, done: true}
        expect(iterator.getPosition()).toEqual Point.infinity()
        expect(iterator.getSourcePosition()).toEqual Point.infinity()

        expect(iterator.next()).toEqual {value: null, done: true}
        expect(iterator.getPosition()).toEqual Point.infinity()
        expect(iterator.getSourcePosition()).toEqual Point.infinity()

    describe "::seek(position)", ->
      it "moves the iterator to the given position in the patch", ->
        iterator = patch.buildIterator()

        iterator.seek(Point(0, 3))
        expect(iterator.getPosition()).toEqual Point(0, 3)
        expect(iterator.getSourcePosition()).toEqual Point(0, 3)

        expect(iterator.next()).toEqual {value: null, done: false}
        expect(iterator.getPosition()).toEqual Point(0, 5)
        expect(iterator.getSourcePosition()).toEqual Point(0, 5)

        iterator.seek(Point(0, 8))
        expect(iterator.getPosition()).toEqual Point(0, 8)
        expect(iterator.getSourcePosition()).toEqual Point(0, 7)

        expect(iterator.next()).toEqual {value: "d", done: false}
        expect(iterator.getPosition()).toEqual Point(0, 9)
        expect(iterator.getSourcePosition()).toEqual Point(0, 7)

        expect(iterator.next()).toEqual {value: null, done: false}
        expect(iterator.getPosition()).toEqual Point(0, 12)
        expect(iterator.getSourcePosition()).toEqual Point(0, 10)

        iterator.seek(Point(0, 13))
        expect(iterator.getPosition()).toEqual Point(0, 13)
        expect(iterator.getSourcePosition()).toEqual Point(0, 11)

        expect(iterator.next()).toEqual {value: "fg", done: false}
        expect(iterator.getPosition()).toEqual Point(0, 15)
        expect(iterator.getSourcePosition()).toEqual Point(0, 14)
