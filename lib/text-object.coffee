{Range, Point} = require 'atom'
_ = require 'underscore-plus'

# [TODO] Need overhaul
#  - [ ] Make expandable by selection.getBufferRange().union(@getRange(selection))
#  - [ ] Count support(priority low)?
Base = require './base'
swrap = require './selection-wrapper'
{
  getLineTextToBufferPosition
  getCodeFoldRowRanges
  isIncludeFunctionScopeForRow
  expandRangeToWhiteSpaces
  getVisibleBufferRange
  translatePointAndClip
  getBufferRows
  getValidVimBufferRow
  trimRange
  sortRanges
  pointIsAtEndOfLine
} = require './utils'
{BracketFinder, QuoteFinder, TagFinder} = require './pair-finder.coffee'

class TextObject extends Base
  @extend(false)
  wise: 'characterwise'
  supportCount: false # FIXME #472, #66
  selectOnce: false

  @deriveInnerAndA: ->
    @generateClass("A" + @name, false)
    @generateClass("Inner" + @name, true)

  @deriveInnerAndAForAllowForwarding: ->
    @generateClass("A" + @name + "AllowForwarding", false, true)
    @generateClass("Inner" + @name + "AllowForwarding", true, true)

  @generateClass: (klassName, inner, allowForwarding) ->
    klass = class extends this
    Object.defineProperty klass, 'name', get: -> klassName
    klass::inner = inner
    klass::allowForwarding = true if allowForwarding
    klass.extend()

  constructor: ->
    super
    @initialize()

  isInner: ->
    @inner

  isA: ->
    not @isInner()

  isLinewise: ->
    @wise is 'linewise'

  isBlockwise: ->
    @wise is 'blockwise'

  getNormalizedHeadBufferPosition: (selection) ->
    point = selection.getHeadBufferPosition()
    if @isMode('visual') and not selection.isReversed()
      translatePointAndClip(@editor, point, 'backward')
    else
      point

  resetState: ->
    @selectSucceeded = null

  execute: ->
    @resetState()

    # Whennever TextObject is executed, it has @operator
    # Called from Operator::selectTarget()
    #  - `v i p`, is `Select` operator with @target = `InnerParagraph`.
    #  - `d i p`, is `Delete` operator with @target = `InnerParagraph`.
    if @operator?
      @select()
    else
      throw new Error('in TextObject: Must not happen')

  select: ->
    @countTimes @getCount(), ({stop}) =>
      stop() unless @supportCount # quick-fix for #560
      for selection in @editor.getSelections()
        oldRange = selection.getBufferRange()
        if @selectTextObject(selection)
          @selectSucceeded = true
        stop() if selection.getBufferRange().isEqual(oldRange)
        break if @selectOnce

    @editor.mergeIntersectingSelections()
    # Some TextObject's wise is NOT deterministic. It has to be detected from selected range.
    @wise ?= swrap.detectWise(@editor)

  # Return true or false
  selectTextObject: (selection) ->
    if range = @getRange(selection)
      swrap(selection).setBufferRange(range)
      return true

  # to override
  getRange: ->
    null

# Section: Word
# =========================
class Word extends TextObject
  @extend(false)
  @deriveInnerAndA()

  getRange: (selection) ->
    point = @getNormalizedHeadBufferPosition(selection)
    {range} = @getWordBufferRangeAndKindAtBufferPosition(point, {@wordRegex})
    if @isA()
      expandRangeToWhiteSpaces(@editor, range)
    else
      range

class WholeWord extends Word
  @extend(false)
  @deriveInnerAndA()
  wordRegex: /\S+/

# Just include _, -
class SmartWord extends Word
  @extend(false)
  @deriveInnerAndA()
  @description: "A word that consists of alphanumeric chars(`/[A-Za-z0-9_]/`) and hyphen `-`"
  wordRegex: /[\w-]+/

# Just include _, -
class Subword extends Word
  @extend(false)
  @deriveInnerAndA()
  getRange: (selection) ->
    @wordRegex = selection.cursor.subwordRegExp()
    super

# Section: Pair
# =========================
class Pair extends TextObject
  @extend(false)
  supportCount: true
  allowNextLine: null
  adjustInnerRange: true
  pair: null

  isAllowNextLine: ->
    @allowNextLine ? (@pair? and @pair[0] isnt @pair[1])

  adjustRange: ({start, end}) ->
    # Dirty work to feel natural for human, to behave compatible with pure Vim.
    # Where this adjustment appear is in following situation.
    # op-1: `ci{` replace only 2nd line
    # op-2: `di{` delete only 2nd line.
    # text:
    #  {
    #    aaa
    #  }
    if pointIsAtEndOfLine(@editor, start)
      start = start.traverse([1, 0])

    if getLineTextToBufferPosition(@editor, end).match(/^\s*$/)
      if @isMode('visual')
        # This is slightly innconsistent with regular Vim
        # - regular Vim: select new line after EOL
        # - vim-mode-plus: select to EOL(before new line)
        # This is intentional since to make submode `characterwise` when auto-detect submode
        # innerEnd = new Point(innerEnd.row - 1, Infinity)
        end = new Point(end.row - 1, Infinity)
      else
        end = new Point(end.row, 0)

    new Range(start, end)

  getFinder: ->
    options = {allowNextLine: @isAllowNextLine(), @allowForwarding, @pair}
    if @pair[0] is @pair[1]
      new QuoteFinder(@editor, options)
    else
      new BracketFinder(@editor, options)

  getPairInfo: (from) ->
    pairInfo = @getFinder().find(from)
    unless pairInfo?
      return null
    pairInfo.innerRange = @adjustRange(pairInfo.innerRange) if @adjustInnerRange
    pairInfo.targetRange = if @isInner() then pairInfo.innerRange else pairInfo.aRange
    pairInfo

  getPointToSearchFrom: (selection, searchFrom) ->
    switch searchFrom
      when 'head' then @getNormalizedHeadBufferPosition(selection)
      when 'start' then swrap(selection).getBufferPositionFor('start')

  # Allow override @allowForwarding by 2nd argument.
  getRange: (selection, options={}) ->
    {allowForwarding, searchFrom} = options
    searchFrom ?= 'head'
    @allowForwarding = allowForwarding if allowForwarding?
    originalRange = selection.getBufferRange()
    pairInfo = @getPairInfo(@getPointToSearchFrom(selection, searchFrom))
    # When range was same, try to expand range
    if pairInfo?.targetRange.isEqual(originalRange)
      pairInfo = @getPairInfo(pairInfo.aRange.end)
    pairInfo?.targetRange

# Used by DeleteSurround
class APair extends Pair
  @extend(false)

class AnyPair extends Pair
  @extend(false)
  @deriveInnerAndA()
  allowForwarding: false
  member: [
    'DoubleQuote', 'SingleQuote', 'BackTick',
    'CurlyBracket', 'AngleBracket', 'SquareBracket', 'Parenthesis'
  ]

  getRangeBy: (klass, selection) ->
    @new(klass).getRange(selection, {@allowForwarding, @searchFrom})

  getRanges: (selection) ->
    prefix = if @isInner() then 'Inner' else 'A'
    ranges = []
    for klass in @member when range = @getRangeBy(prefix + klass, selection)
      ranges.push(range)
    ranges

  getRange: (selection) ->
    ranges = @getRanges(selection)
    _.last(sortRanges(ranges)) if ranges.length

class AnyPairAllowForwarding extends AnyPair
  @extend(false)
  @deriveInnerAndA()
  @description: "Range surrounded by auto-detected paired chars from enclosed and forwarding area"
  allowForwarding: true
  searchFrom: 'start'
  getRange: (selection) ->
    ranges = @getRanges(selection)
    from = selection.cursor.getBufferPosition()
    [forwardingRanges, enclosingRanges] = _.partition ranges, (range) ->
      range.start.isGreaterThanOrEqual(from)
    enclosingRange = _.last(sortRanges(enclosingRanges))
    forwardingRanges = sortRanges(forwardingRanges)

    # When enclosingRange is exists,
    # We don't go across enclosingRange.end.
    # So choose from ranges contained in enclosingRange.
    if enclosingRange
      forwardingRanges = forwardingRanges.filter (range) ->
        enclosingRange.containsRange(range)

    forwardingRanges[0] or enclosingRange

class AnyQuote extends AnyPair
  @extend(false)
  @deriveInnerAndA()
  allowForwarding: true
  member: ['DoubleQuote', 'SingleQuote', 'BackTick']
  getRange: (selection) ->
    ranges = @getRanges(selection)
    # Pick range which end.colum is leftmost(mean, closed first)
    _.first(_.sortBy(ranges, (r) -> r.end.column)) if ranges.length

class Quote extends Pair
  @extend(false)
  allowForwarding: true

class DoubleQuote extends Quote
  @extend(false)
  @deriveInnerAndA()
  pair: ['"', '"']

class SingleQuote extends Quote
  @extend(false)
  @deriveInnerAndA()
  pair: ["'", "'"]

class BackTick extends Quote
  @extend(false)
  @deriveInnerAndA()
  pair: ['`', '`']

class CurlyBracket extends Pair
  @extend(false)
  @deriveInnerAndA()
  @deriveInnerAndAForAllowForwarding()
  pair: ['{', '}']

class SquareBracket extends Pair
  @extend(false)
  @deriveInnerAndA()
  @deriveInnerAndAForAllowForwarding()
  pair: ['[', ']']

class Parenthesis extends Pair
  @extend(false)
  @deriveInnerAndA()
  @deriveInnerAndAForAllowForwarding()
  pair: ['(', ')']

class AngleBracket extends Pair
  @extend(false)
  @deriveInnerAndA()
  @deriveInnerAndAForAllowForwarding()
  pair: ['<', '>']

class Tag extends Pair
  @extend(false)
  @deriveInnerAndA()
  allowNextLine: true
  allowForwarding: true
  adjustInnerRange: false

  getTagStartPoint: (from) ->
    tagRange = null
    pattern = TagFinder::pattern
    @scanForward pattern, {from: [from.row, 0]}, ({range, stop}) ->
      if range.containsPoint(from, true)
        tagRange = range
        stop()
    tagRange?.start

  getFinder: ->
    new TagFinder(@editor, {allowNextLine: @isAllowNextLine(), @allowForwarding})

  getPairInfo: (from) ->
    super(@getTagStartPoint(from) ? from)

# Section: Paragraph
# =========================
# Paragraph is defined as consecutive (non-)blank-line.
class Paragraph extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: 'linewise'
  supportCount: true

  findRow: (fromRow, direction, fn) ->
    fn.reset?()
    foundRow = fromRow
    for row in getBufferRows(@editor, {startRow: fromRow, direction})
      break unless fn(row, direction)
      foundRow = row

    foundRow

  findRowRangeBy: (fromRow, fn) ->
    startRow = @findRow(fromRow, 'previous', fn)
    endRow = @findRow(fromRow, 'next', fn)
    [startRow, endRow]

  getPredictFunction: (fromRow, selection) ->
    fromRowResult = @editor.isBufferRowBlank(fromRow)

    if @isInner()
      predict = (row, direction) =>
        @editor.isBufferRowBlank(row) is fromRowResult
    else
      if selection.isReversed()
        directionToExtend = 'previous'
      else
        directionToExtend = 'next'

      flip = false
      predict = (row, direction) =>
        result = @editor.isBufferRowBlank(row) is fromRowResult
        if flip
          not result
        else
          if (not result) and (direction is directionToExtend)
            flip = true
            return true
          result

      predict.reset = ->
        flip = false
    predict

  getRange: (selection) ->
    originalRange = selection.getBufferRange()
    fromRow = @getNormalizedHeadBufferPosition(selection).row

    if @isMode('visual', 'linewise')
      if selection.isReversed()
        fromRow--
      else
        fromRow++
      fromRow = getValidVimBufferRow(@editor, fromRow)

    rowRange = @findRowRangeBy(fromRow, @getPredictFunction(fromRow, selection))
    selection.getBufferRange().union(@getBufferRangeForRowRange(rowRange))

class Indentation extends Paragraph
  @extend(false)
  @deriveInnerAndA()

  getRange: (selection) ->
    fromRow = @getNormalizedHeadBufferPosition(selection).row

    baseIndentLevel = @getIndentLevelForBufferRow(fromRow)
    predict = (row) =>
      if @editor.isBufferRowBlank(row)
        @isA()
      else
        @getIndentLevelForBufferRow(row) >= baseIndentLevel

    rowRange = @findRowRangeBy(fromRow, predict)
    @getBufferRangeForRowRange(rowRange)

# Section: Comment
# =========================
class Comment extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: 'linewise'

  getRange: (selection) ->
    row = swrap(selection).getStartRow()
    rowRange = @editor.languageMode.rowRangeForCommentAtBufferRow(row)
    rowRange ?= [row, row] if @editor.isBufferRowCommented(row)
    if rowRange?
      @getBufferRangeForRowRange(rowRange)

# Section: Fold
# =========================
class Fold extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: 'linewise'

  adjustRowRange: (rowRange) ->
    return rowRange if @isA()

    [startRow, endRow] = rowRange
    if @getIndentLevelForBufferRow(startRow) is @getIndentLevelForBufferRow(endRow)
      endRow -= 1
    startRow += 1
    [startRow, endRow]

  getFoldRowRangesContainsForRow: (row) ->
    getCodeFoldRowRanges(@editor)
      .filter ([startRow, endRow]) -> startRow <= row <= endRow
      .reverse()

  getRange: (selection) ->
    rowRanges = @getFoldRowRangesContainsForRow(swrap(selection).getStartRow())
    return unless rowRanges.length

    popNextBufferRange = =>
      @getBufferRangeForRowRange(@adjustRowRange(rowRanges.shift()))

    range = popNextBufferRange()
    if rowRanges.length and range.isEqual(selection.getBufferRange())
      popNextBufferRange()
    else
      range

# NOTE: Function range determination is depending on fold.
class Function extends Fold
  @extend(false)
  @deriveInnerAndA()
  # Some language don't include closing `}` into fold.
  scopeNamesOmittingEndRow: ['source.go', 'source.elixir']

  getFoldRowRangesContainsForRow: (row) ->
    (super).filter (rowRange) =>
      isIncludeFunctionScopeForRow(@editor, rowRange[0])

  adjustRowRange: (rowRange) ->
    [startRow, endRow] = super
    # NOTE: This adjustment shoud not be necessary if language-syntax is properly defined.
    if @isA() and @editor.getGrammar().scopeName in @scopeNamesOmittingEndRow
      endRow += 1
    [startRow, endRow]

# Section: Other
# =========================
class CurrentLine extends TextObject
  @extend(false)
  @deriveInnerAndA()

  getRange: (selection) ->
    row = @getNormalizedHeadBufferPosition(selection).row
    range = @editor.bufferRangeForBufferRow(row)
    if @isA()
      range
    else
      trimRange(@editor, range)

class Entire extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: 'linewise'
  selectOnce: true

  getRange: (selection) ->
    @editor.buffer.getRange()

class Empty extends TextObject
  @extend(false)
  selectOnce: true

class LatestChange extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: null
  selectOnce: true
  getRange: ->
    @vimState.mark.getRange('[', ']')

class SearchMatchForward extends TextObject
  @extend()
  backward: false

  findMatch: (fromPoint, pattern) ->
    fromPoint = translatePointAndClip(@editor, fromPoint, "forward") if @isMode('visual')
    found = null
    @scanForward pattern, {from: [fromPoint.row, 0]}, ({range, stop}) ->
      if range.end.isGreaterThan(fromPoint)
        found = range
        stop()
    {range: found, whichIsHead: 'end'}

  getRange: (selection) ->
    pattern = @globalState.get('lastSearchPattern')
    return unless pattern?

    fromPoint = selection.getHeadBufferPosition()
    {range, whichIsHead} = @findMatch(fromPoint, pattern)
    if range?
      @unionRangeAndDetermineReversedState(selection, range, whichIsHead)

  unionRangeAndDetermineReversedState: (selection, found, whichIsHead) ->
    if selection.isEmpty()
      found
    else
      head = found[whichIsHead]
      tail = selection.getTailBufferPosition()

      if @backward
        head = translatePointAndClip(@editor, head, 'forward') if tail.isLessThan(head)
      else
        head = translatePointAndClip(@editor, head, 'backward') if head.isLessThan(tail)

      @reversed = head.isLessThan(tail)
      new Range(tail, head).union(swrap(selection).getTailBufferRange())

  selectTextObject: (selection) ->
    if range = @getRange(selection)
      swrap(selection).setBufferRange(range, {reversed: @reversed ? @backward})
      return true

class SearchMatchBackward extends SearchMatchForward
  @extend()
  backward: true

  findMatch: (fromPoint, pattern) ->
    fromPoint = translatePointAndClip(@editor, fromPoint, "backward") if @isMode('visual')
    found = null
    @scanBackward pattern, {from: [fromPoint.row, Infinity]}, ({range, stop}) ->
      if range.start.isLessThan(fromPoint)
        found = range
        stop()
    {range: found, whichIsHead: 'start'}

# [Limitation: won't fix]: Selected range is not submode aware. always characterwise.
# So even if original selection was vL or vB, selected range by this text-object
# is always vC range.
class PreviousSelection extends TextObject
  @extend()
  wise: null
  selectOnce: true

  selectTextObject: (selection) ->
    {properties, submode} = @vimState.previousSelection
    if properties? and submode?
      @wise = submode
      selection = @editor.getLastSelection()
      swrap(selection).selectByProperties(properties, keepGoalColumn: false)
      return true

class PersistentSelection extends TextObject
  @extend(false)
  @deriveInnerAndA()
  wise: null
  selectOnce: true

  selectTextObject: (selection) ->
    if @vimState.hasPersistentSelections()
      @vimState.persistentSelection.setSelectedBufferRanges()
      return true

class VisibleArea extends TextObject
  @extend(false)
  @deriveInnerAndA()
  selectOnce: true

  getRange: (selection) ->
    # [BUG?] Need translate to shilnk top and bottom to fit actual row.
    # The reason I need -2 at bottom is because of status bar?
    bufferRange = getVisibleBufferRange(@editor)
    if bufferRange.getRows() > @editor.getRowsPerPage()
      bufferRange.translate([+1, 0], [-3, 0])
    else
      bufferRange
