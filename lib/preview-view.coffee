_ = require 'underscore'
{SourceMapConsumer} = require 'source-map'
{CompositeDisposable, TextEditor} = require 'atom'

module.exports =
class PreviewView
  alive: true

  constructor: (@editor, @provider) ->
    @previewEditor = new TextEditor
    grammar = atom.grammars.grammarForScopeName(@provider.toScopeName)
    @previewEditor.setGrammar(grammar) if grammar
    @previewEditor.getTitle = -> 'Source Preview'

    @subscriptions = new CompositeDisposable
    @subscriptions.add(atom.config.observe('source-preview.RefreshDebouncePeriod', (wait) =>
      @debouncedRenderPreview = _.debounce(@renderPreview, wait)
    ))
    @debouncedSyncScroll = _.debounce(@syncScroll, 200)

    @handleEvents()
    @renderPreview()
    @syncScroll()

  destroy: =>
    return unless @isAlive()
    @alive = false
    @pane?.destroyItem(@previewEditor)
    @pane?.destroy()
    @pane = null
    @previewEditor?.destroy()
    @previewEditor = null
    @sourceMap = null
    @editor = null
    @provider = null
    @subscriptions?.dispose()
    @subscriptions = null

  isAlive: ->
    @alive

  handleEvents: ->
    @subscriptions.add(@editor.onDidStopChanging(@changeHandler))
    @subscriptions.add(@editor.onDidChangeCursorPosition(@changePositionHandler))
    @subscriptions.add(@editor.onDidDestroy(@destroy))
    @subscriptions.add(@previewEditor.onDidDestroy(@destroy))
    @subscriptions.add(atom.workspace.onDidChangeActivePaneItem(@changeItemHandler))

  changeHandler: =>
    @debouncedRenderPreview()

  changePositionHandler: ({oldBufferPosition, newBufferPosition}) =>
    @debouncedSyncScroll()

  changeItemHandler: (item) =>
    @destroy() unless item in [@editor, @previewEditor]

  syncScroll: =>
    return unless atom.config.get('source-preview.enableSyncScroll')

    bufferRow = @editor.getCursorBufferPosition().row
    previewRow = @generatedRowFor()
    return unless previewRow?

    @previewEditor.setCursorBufferPosition([previewRow, 0])
    @previewEditor.clearSelections()
    @previewEditor.selectLinesContainingCursors()
    @recenterTopBottom(@previewEditor)

  generatedRowFor: ->
    return unless @sourceMap?
    pos = @editor.getCursorBufferPosition()
    {line} = @sourceMap.generatedPositionFor(
      source: @sourceMap.sources[0]
      line: pos.row + 1
      column: pos.column + 1
    )
    line - 1

  renderPreview: =>
    @errorNotification?.dismiss()
    @errorNotification = null

    try
      options =
        sourceMap: atom.config.get('source-preview.enableSyncScroll')
        bare: atom.config.get('source-preview.coffeeProviderOptionBare')
        filePath: @editor.getPath()

      {code, sourceMap} = @provider.transform(@editor.getText(), options)
      @previewEditor.setText(code)
      @sourceMap = new SourceMapConsumer(sourceMap) if sourceMap
      @debouncedSyncScroll()
    catch error
      @errorNotification = atom.notifications.addError('source-preview compile error', {
        dismissable: true
        detail: error.toString()
      })

  show: ->
    srcPane = atom.workspace.getActivePane()

    if pane = @getAdjacentPane()
      pane.activateItem(@previewEditor)
    else
      @pane = srcPane.splitRight(items: [@previewEditor])

    srcPane.activate()
    editorElement = atom.views.getView(@previewEditor)
    atom.commands.add(editorElement, 'source-preview:toggle', @destroy)

  getAdjacentPane: ->
    pane = atom.workspace.getActivePane()
    return unless children = pane.getParent().getChildren?()
    index = children.indexOf pane
    console.log 'children', children, index

    _.chain([children[index-1], children[index+1]])
      .filter (pane) ->
        pane?.constructor?.name is 'Pane'
      .last()
      .value()

  recenterTopBottom: (editor) ->
    editorElement = atom.views.getView(editor)
    minRow = Math.min((c.getBufferRow() for c in editor.getCursors())...)
    maxRow = Math.max((c.getBufferRow() for c in editor.getCursors())...)
    minOffset = editorElement.pixelPositionForBufferPosition([minRow, 0])
    maxOffset = editorElement.pixelPositionForBufferPosition([maxRow, 0])
    editor.setScrollTop((minOffset.top + maxOffset.top - editor.getHeight())/2)
