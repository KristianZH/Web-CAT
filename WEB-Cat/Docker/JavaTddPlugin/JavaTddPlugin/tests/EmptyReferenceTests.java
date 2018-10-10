// -------------------------------------------------------------------------
/**
 *  A simple, empty test class with a single test case method that
 *  always passes.
 *
 *  @author  stedwar2
 *  @version $Id: EmptyReferenceTests.java,v 1.1 2008/03/25 15:34:32 stedwar2 Exp $
 */
public class EmptyReferenceTests
    extends junit.framework.TestCase
{
    //~ Instance/static variables .............................................


    //~ Constructor ...........................................................

    // ----------------------------------------------------------
    /**
     * Creates a new test object.
     */
    public EmptyReferenceTests()
    {
        // Nothing to do
    }


    //~ Methods ...............................................................

    // ----------------------------------------------------------
    /**
     * Sets up the test fixture.
     * Called before every test case method.
     */
    protected void setUp()
    {
        System.out.println( "executing instructor empty test" );
    }


    // ----------------------------------------------------------
    /**
     * A test that always passes.
     */
    public void testBlank()
    {
        // Always pass, no assertions
    }
}
