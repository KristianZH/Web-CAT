// $Id: junit.js,v 1.1 2011/03/07 19:24:07 aallowat Exp $

(function() {
    /*
     * Private helper functions for working with the DOM.
     * This is reinventing the wheel a little, but I didn't want to
     * depend on Dojo here, and these functions are simple enough.
     */
    var $ = function(id)
    {
        return document.getElementById(id);
    };
    var $C = function(cls)
    {
        return document.getElementsByClassName(cls);
    };
    var addClass = function(elem, cls)
    {
        if (elem.className)
        {
            elem.className += ' ' + cls;
        }
        else
        {
            elem.className = cls;
        }
    };
    var removeClass = function(elem, cls)
    {
        elem.className = elem.className.replace(
            new RegExp('(^|\\s+)' + cls, 'g'), '');
    };
    var scrollToElement = function(container, element)
    {
        var selectedPosX = 0;
        var selectedPosY = 0;

        while (element != container && element != null)
        {
            selectedPosX += element.offsetLeft;
            selectedPosY += element.offsetTop;
            element = element.offsetParent;
        }

        if (element != null)
        {
            element.scrollTop = selectedPosY;
        }
    };

    var junitViewLastSelectedTest = null;

    /*
     * Toggles the display of the tests in a suite.
     */
    junitViewToggleSuite = function(id)
    {
        var testsNode = $(id + '_tests');
        var togglerNode = $(id + '_toggler');

        if (testsNode.style.display == 'none')
        {
            testsNode.style.display = 'block';
            togglerNode.className = 'junit-suite-expanded';
        }
        else
        {
            testsNode.style.display = 'none';
            togglerNode.className = 'junit-suite-collapsed';
        }
    };

    /*
     * Selects the specified test in the view and optionally scrolls it
     * into view.
     */
    junitViewSetSelectedTrace = function(id, scroll)
    {
        var oldBlock = junitViewLastSelectedTest + '_block';
        var newBlock = id + '_block';

        if (junitViewLastSelectedTest)
        {
            removeClass($(junitViewLastSelectedTest).parentNode,
                'junit-selected');
        }
        addClass($(id).parentNode, 'junit-selected');

        if ($(oldBlock))
        {
            $(oldBlock).style.display = "none";
        }

        if ($(newBlock))
        {
            $(newBlock).style.display = "block";
        }

        if (scroll && $(newBlock))
        {
            scrollToElement($C('junit-tests')[0], $(id));
        }
        junitViewLastSelectedTest = id;
    };
})();
