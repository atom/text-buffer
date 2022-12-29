Range = require '../src/range'

describe "Range", ->
  beforeEach ->
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)

  describe "::fromObject() when object is falsy", ->
    it "should not throw", ->
      expect(-> Range.fromObject(null)).not.toThrow()
    it "should get default values", ->
      expect(Range.fromObject(null).toString()).toBe "[(0, 0) - (0, 0)]"

  describe "::intersectsWith(other, [exclusive])", ->
    intersectsWith = (range1, range2, exclusive) ->
      range1 = Range.fromObject(range1)
      range2 = Range.fromObject(range2)
      range1.intersectsWith(range2, exclusive)

    describe "when the exclusive argument is false (the default)", ->
      it "returns true if the ranges intersect, exclusive of their endpoints", ->
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 0], [1, 1]])).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 1], [1, 2]])).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 1], [1, 3]])).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 4], [4, 5]])).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 3], [4, 5]])).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 5], [2, 2]])).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 5], [4, 4]])).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 2], [1, 2]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 4], [3, 4]], true)).toBe false

    describe "when the exclusive argument is true", ->
      it "returns true if the ranges intersect, exclusive of their endpoints", ->
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 0], [1, 1]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 1], [1, 2]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 1], [1, 3]], true)).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 4], [4, 5]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 3], [4, 5]], true)).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 5], [2, 2]], true)).toBe true
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 5], [4, 4]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[1, 2], [1, 2]], true)).toBe false
        expect(intersectsWith([[1, 2], [3, 4]], [[3, 4], [3, 4]], true)).toBe false

  describe "::negate()", ->
    it "should negate the start and end points", ->
      expect(new Range([ 0,  0], [ 0,  0]).negate().toString()).toBe "[(0, 0) - (0, 0)]"
      expect(new Range([ 1,  2], [ 3,  4]).negate().toString()).toBe "[(-3, -4) - (-1, -2)]"
      expect(new Range([-1, -2], [-3, -4]).negate().toString()).toBe "[(1, 2) - (3, 4)]"
      expect(new Range([-1,  2], [ 3, -4]).negate().toString()).toBe "[(-3, 4) - (1, -2)]"
