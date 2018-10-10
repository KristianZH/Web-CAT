dojo.declare("webcat.batchprocessor.BatchResultWatcher", null,
{
    // ----------------------------------------------------------
    constructor: function(pageContainerID)
    {
        this._started = false;
        this._isComplete = false;
        this._pageContainerID = pageContainerID;
    },


    // ----------------------------------------------------------
    start: function()
    {
        if (!this._started)
        {
            this._interval = setInterval(dojo.hitch(this, function() {
                webcat.refresh(this._pageContainerID);
            }), 5000);

            this._started = true;
        }
    },


    // ----------------------------------------------------------
    stop: function()
    {
        if (this._interval)
        {
            clearInterval(this._interval);
        }
    },


    // ----------------------------------------------------------
    _updatePageIndicator: function()
    {
        if (!this._pagesSoFar)
        {
            dojo.byId("pageIndicator").innerHTML = "No pages available yet";
        }
        else
        {
            var pageIndicator = "Page "
               + this._currentPage + " (of " + this._pagesSoFar;

            pageIndicator += (this._isComplete == true) ?
                " total)" : " so far)";
            dojo.byId("pageIndicator").innerHTML = pageIndicator;
        }

        if (this._isComplete)
        {
            // Update the popup menu so that the user can save the report.
            dijit.byId("saveDialogContainer").refresh();
        }

        if (this._hasErrors)
        {
           dijit.byId("errorBlock").refresh();
        }
    },


    // ----------------------------------------------------------
    stop: function()
    {
        clearInterval(this._interval);
        delete this._interval;
    },


    // ----------------------------------------------------------
    goToFirstPage: function()
    {
        if (this._pagesSoFar == 0) return;

        this._currentPage = 1;
        this._loadPage();
    },


    // ----------------------------------------------------------
    goToPreviousPage: function()
    {
        if (this._pagesSoFar == 0) return;

        if (this._currentPage > 1)
            this._currentPage--;

        this._loadPage();
    },


    // ----------------------------------------------------------
    goToNextPage: function()
    {
        if (this._pagesSoFar == 0) return;

        if (this._currentPage < this._pagesSoFar)
            this._currentPage++;

        this._loadPage();
    },


    // ----------------------------------------------------------
    goToLastPage: function()
    {
        if (this._pagesSoFar == 0) return;

        this._currentPage = this._pagesSoFar;
        this._loadPage();
    },


    // ----------------------------------------------------------
    cancel: function()
    {
        dijit.byId("cancelButton").attr("label", "Canceling...");
        dijit.byId("cancelButton").attr("disabled", true);
        this._pageRPC.cancelReport();
    }
});
