package Web_CAT::ErrorMapper;

use warnings;
use strict;
use Carp qw(cluck croak);
use File::stat;
use Web_CAT::Utilities qw(htmlEscape);
use Data::Dumper;
use Class::Struct;
use vars qw(@ISA @EXPORT_OK);

use Exporter qw(import);

@ISA = qw(Exporter);

@EXPORT_OK = qw(
    compilerErrorHintKey
    runtimeErrorHintKey
    compilerErrorEnhancedMessage
    setResultDir
    codingStyleMessageValue
    );

# Compiler Errors: "Error Message" is the key and the anchor tag from below url
# is the value (used by virtualTA)
# http://mindprod.com/jgloss/compileerrormessages.html
my %compilerErrors = (
    '\'\(\' expected'            => 'PARENEXPECTED',
    '\'\.\' expected'            => 'DOTEXPECTED',
    '\'\.class\' expected'            => 'DOTCLASSEXPECTED',
    '\';\' expected'            => 'SEMICOLONEXPECTED',
    '\';\' missing'                => 'SEMICOLONMISSING',
    '\'=\' expected'            => 'EQUALEXPECTED',
    '\'\[\' expected'            => 'BRACKETEXPECTED',
    'already defined'            => 'ALREADYDEFINED',
    'ambiguous class'            => 'AMBIGUOUS',
    'array not initialised'            => 'ARRAYNOTINITIALISED',
    'attempt to reference'            => 'ATTEMPTOREFERENCE',
    'attempt to rename'            => 'ATTEMPTORENAME',
    'bad class file'            => 'BADCLASSFILE',
    'blank final'                => 'BLANKFINAL',
    'boolean cannot be dereferenced'     => 'BOOLEANDEREFERENCED',
    'Bound mismatch'            => 'BOUNDMISMATCH',
    'can\'t access class'            => 'CANTACCESSCLASS',
    'can\'t be applied'            => 'CANTBEAPPLIED',
    'can\'t be dereferenced'        => 'CANTBEDEREFERENCED',
    'can\'t be instantiated'        => 'CANTBEINSTANTIATED',
    'can\'t convert from Object to X'     => 'CANTCONVERT',
    'can\'t determine application home'     => 'CANTDETERMINEAPPLICATIONHOME',
    'cannot find symbol'                => 'CANNOTFINDSYMBOL',
    'can\'t instantiate abstract class'     => 'CANTINSTANTIATEABSTRACT',
    'cannot make a static reference'     => 'CANTMAKESTATICREF',
    'cannot override'            => 'CANTOVERIDE',
    'cannot resolve constructor'         => 'CANNOTRESOLVECONSTRUCTOR',
    'cannot resolve symbol'                 => 'CANNOTRESOLVESYMBOL',
    'cannot resolve symbol constructor Thread' => 'CANNOTRESOLVETHREADCONSTRUCTOR',
    'cannot resolve symbol this'        => 'CANNOTRESOLVETHIS',
    'cannot use operator new'        => 'CANNOTUSENEW',
    'can\'t delete jar file'        => 'CANTDELETEJAR',
    'char cannot be dereferenced'           => 'CHARCANNOTBEDEREFERENCED',
    'clashes with package'            => 'CLASHESWITHPACKAGE',
    'class has wrong version'        => 'CLASSHASWRONGVERSION',
    'class must be defined in a file'    => 'MUSTBEDEFINEDINAFILE',
    'class names only accepted for annotation processing' => 'CLASSNAMESONLYACCEPTED',
    'class names unchecked only accepted for annotation processing' => 'CLASSNAMESUNCHKCDKD',        => ,
    'class not found'            => 'CLASSNOTFOUND',
    'class not found in import'        => 'CLASSNOTFOUNDINIMPORT',
    'class not found in type declaration'    => 'CLASSNOTFOUNDINTYPEDEF',
    'class expected'            => 'CLASSPLAINEXPECTED',
    'class or interface (or enum) declaration expected'    => 'CLASSDCLEXPECTED',
    'class, enum or interface expected'    => 'CLASSEXPECTED',
    'class should be declared in file'    => 'CLASSSHOULDBEDCLED',
    'classname not enclosing class'        => 'CLASSNAMENOTENCLOSING',
    'Comparable cannot be inherited'    => 'COMPARABLE',
    'duplicate class'            => 'DUPLICATECLASS',
    'duplicate methods'            => 'DUPLICATEMETHODS',
    'enum as identifier'            => 'ENUMASIDENTIFIER',
    'error while writing'            => 'WRITING',
    'Exception never thrown'        => 'EXCEPTIONNEVERTHROWN',
    'final parameter (.*) may not be assigned' => 'FINALPARAMETER',
    'generic array creation'        => 'GENERICARRAY',
    'identifier expected'            => 'IDENTIFIEREXPECTED',
    'illegal character'            => 'ILLEGALCHARACTER',
    'illegal escape'            => 'ILLEGALESCAPE',
    'illegal forward reference'        => 'ILLEGALFORWARD',
    'illegal reference to static'        => 'ILLEGALSTATICREF',
    'illegal start'                => 'ILLEGALSTART',
    'incompatible type'            => 'INCOMPATIBLETYPE',
    'instance not accessible'        => 'INSTANCENOTACCESSIBLE',
    'invalid declaration'            => 'INVALIDDCL',
    'invalid label'                => 'INVALIDLABEL',
    'invalid flag'                => 'INVALIDFLAG',
    'invalid method'            => 'INVALIDMETHOD',
    'invalid type'                => 'INVALIDTYPE',
    'javac is not a … command'        => 'JAVAC',
    'main must be static void'        => 'MAINMUSTBESTATIC',
    'method cannot hide'            => 'METHODCANTHIDE',
    'method clone not visible'        => 'METHODCLONE',
    'method matches constructor name'    => 'METHODMATECHESCONSTRUCTOR',
    'method not found'            => 'METHODNOTFOUND',
    'misplaced construct'            => 'MISPLACEDCONSTRUCT',
    'misplaced package'            => 'MISPLACEDPACKAGE',
    'missing method body'            => 'MISSINGMETHODBODY',
    'missing return statement'        => 'MISSINGRETURN',
    'modifier synchronized not allowed' => 'MODIFIERSYNCHRONIZED',
    'name of constructor mismatch'        => 'CONSTRUCTORMISMATCH',
    'no field'                => 'LENGTH',
    'no method found'            => 'NOMETHODFOUND',
    'no method matching'            => 'NOMETHODMATCHING',
    'cap missing'                => 'CAPS',
    'impotent setters'            => 'IMPOTENTSETTER',
    'missing public'            => 'MISSINGPUBLIC',
    'case fallthru'                => 'CASEFALLTHRU',
    'missing initialisation'        => 'MISSINGINIT',
    'missing variable initialiser'        => 'MISSINGVARINIT',
    'constructor treated as method'        => 'FAKECONSTRUCTOR',
    'suspicious shadowing'            => 'SUPICIOUSSHADOWING',
    'calling overridden methods in constructor' => 'OVERRIDDENCALLSINCONSTRUCTOR',
    'non-final variable'            => 'NONFINALVAR',
    'non-static can\'t be referenced'    => 'NONSTATICCANTBEREF',
    'not abstract'                => 'NOTABSTRACT',
    'not a statement'            => 'NOTASTATEMENT',
    'not accessible'            => 'NOTACCESSIBLE',
    'not found in import'            => 'NOTFOUNDINIMPORT',
    'not initialised'            => 'NOTINITIALISED',
    'operator +'                => 'OPERATORPLUS',
    'operator ||'                => 'OPERATOROR',
    'package does not exist'        => 'PACKAGEDOESNTEXIST',
    'Permission denied'            => 'PERMISSIONDENIED',
    'possible loss of precision'        => 'POSSIBLELOSSOFPRECISION',
    'public class should be in file'    => 'PUBLICLASSHOULDBEINFILE',
    'reached end of file'            => 'REACHEDEOF',
    'method already defined'        => 'REDEFINEDMETHOD',
    'Recompile with -Xlint:unchecked'    => 'RECOMPILE',
    'reference ambiguous'            => 'REFERENCEAMBIGUOUS',
    'repeated modifier'            => 'REPEATEDMODIFIER',
    'return in constructor'            => 'RETURNINCONSTRUCTOR',
    'return outside method'            => 'RETURNOUTSIDEMETHOD',
    'return required'            => 'RETURNREQUIRED',
    'serialVersionUID required'        => 'SERIALVERISONUID',
    'should be declared in file'        => 'SHOULDBEDCLEDINFILE',
    'statement expected'            => 'STATEMENTEXPECTED',
    'static not valid on constructor'    => 'STATICONSTRUCTOR',
    'static field should be accessed in a static way'    => 'STATICFIELD',
    'Tag @see : reference not found'    => 'TAGSEE',
    'superclass not found'            => 'SUPERCLASSNOTFOUND',
    'type can\'t be private'        => 'TYPECANTBEPRIVATE',
    'type cannot be widened'        => 'TYPECANTBEWIDENED',
    'type expected'                => 'TYPEEXPECTED',
    'type safety'                => 'TYPESAFETY',
    'type safety: erased type'        => 'TYPESAFETYERASED',
    'unable to resolve class'        => 'UNABLETORESOLVE',
    'unchecked cast'            => 'UNCHECKEDCAST',
    'unchecked conversion'            => 'UNCHECKEDCONVERSION',
    'unclosed character literal'        => 'UNCLOSEDCHARLIT',
    'unclosed string literal'        => 'UNCLOSEDSTRINGLIT',
    'undefined reference to main'        => 'UNDEFINEDREFTOMAIN',
    'undefined variable'            => 'UNDEFINEDVAR',
    'unexpected symbols'            => 'UNEXPECTEDSYMBOLS',
    'unqualified enumeration required'    => 'UNQUALIFIEDENUMERATION',
    'unreachable statement'            => 'UNREACHABLE',
    'unreported exception'            => 'UNREPORTEDEXEPTION',
    'unsorted switch'            => 'UNSORTEDSWITCH',
    'void type'                => 'VOIDTYPE',
    'weaker access'                => 'WEAKERACCESS',
    '\'{\' expected'            => 'OPENBRACEEXPECTED',
    '\'}\' expected'            => 'CLOSEBRACEEXPECTED'
);

# Runtime Errors: "Error Message" is the key and the anchor tag from below url
# is the value (used by virtualTA)
# http://mindprod.com/jgloss/runerrormessages.html
my %runtimeErrors = (
    'AbstractMethodError'            => 'ABSTRACTMETHODERROR',
    'AccessControlException'         => 'ACCESSCONTROLEXCEPTION',
    'Applet not inited'             => 'NOTINITED',
    'Application Failed To Start'       => 'APPFAILEDTOSTART',
    'ArithmeticException'               => 'ARITHMETICEXCEPTION',
    'ArrayIndexOutOfBoundsException'     => 'ARRAYINDEXOUTOFBOUNDS',
    'ArrayStoreException'            => 'ARRAYSTOREEXCEPTION',
    'bad configuration'            => 'BADCONFIGURATION',
    'bad magic number'            => 'BADMAGICNUMBER',
    'bad major'                 => 'BADMAJOR',
    'blank Applet'                => 'BLANKAPPLET',
    'BoxLayout can\'t be shared'        => 'BOXLAYOUT',
    'Broken Pipe'                => 'BROKENPIPE',
    'can\'t create virtual machine'        => 'CANTCREATEVIRTUALMACHINE',
    'CertificateException'            => 'CERTIFICATEEXCEPTION',
    'CharConversionException'        => 'CHARCONVERSIONEXCEPTION',
    'class has wrong version'         => 'CLASSHASWRONGVERSION',
    'class file contains wrong class'       => 'CONTAINSWRONGCLASS',
    'ClassCastException'            => 'CLASSCASTEXCEPTION',
    'ClassFormatError'            => 'CLASSFORMATERROR',
    'ClassNotFoundException'        => 'CLASSNOTFOUNDEXCEPTION',
    'ClientClientTransportException'     => 'CLIENTTRANSPORT',
    'ConcurrentModificationException'       => 'CONCURRENTMOD',
    'ConnectException'            => 'CONNECTEXCEPTION',
    'Could not find or load the main class' => 'COULDNOTFIND',
    'Could not find main class'             => 'NOMAINCLASS',
    'Could not reserve enough space for object heap' => 'RESERVEOBJECTHEAP',
    'does not contain expected'             => 'DOESNTCONTAINEXPECTED',
    'EOFException in ZIP'            => 'EOFEXCEPTION',
    'ExceptionInInitializerError'           => 'ExceptionInInitializerError',
    'Exception in thread'            => 'EXCEPTIONINTHREAD',
    'Handshake Alert'            => 'HANDSHAKEALERT',
    'HeadlessException'            => 'HEADLESSEXCEPTION',
    'IllegalAccessError'            => 'ILLEGALACCESSERROR',
    'IllegalBlockSizeException'        => 'ILLEGALBLOCKSIZEEXCEPTION',
    'IllegalMonitorStateException'        => 'ILLEGALMONITORSTATEEXCEPTION',
    'illegal nonvirtual'            => 'ILLEGALNONVIRTUAL',
    'Image won\'t paint'            => 'WONTPAINT',
    'Identifier Expected'            => 'IDENTIFIEREXPECTED',
    'Incompatible types'                    => 'INCOMPATIBLETYPES',
    'IncompatibleClassChangeError'        => 'INCOMPATIBLECLASSCHANGEERROR',
    'intern overflow'            => 'INTEROVERFLOW',
    'InvalidArgumentException'        => 'INVALIDARGUMENTEXCEPTION',
    'InvalidClassException'            => 'INVALIDCLASS',
    'InvocationTargetException'        => 'INVOCATIONTARGET',
    'IOException'                           => 'IOEXCEPTION',
    'Jar Not Signed With Same Certificate'  => 'JARSNOTSIGNEDWITHSAMECERT',
    'JavaMail obsolete'                     => 'JAVAMAILOBSOLETE',
    'JRE not installed'                     => 'JRENOTINSTALLED',
    'load: class not found'                 => 'LOADCLASSNOTFOUND',
    'method not found'            => 'METHODNOTFOUND',
    'MissingResourceException'        => 'MISSINGRESOURCEEXCEPTION',
    'NoClassDefFoundError'            => 'NOCLASSDEFFOUNDERROR',
    'NoInitialContextException'             => 'NOINITIALCONTEXTEXCEPTION',
    'NoSuchElementException'        => 'NOSUCHELEMENTEXCEPTION',
    'NoSuchFieldError'            => 'NOSUCHFIELDERROR',
    'NoSuchMethodError'            => 'NOSUCHMETHODERROR',
    'NoSuchProviderException'        => 'NOSUCHPROVIDEREXCEPTION',
    'NotSerializableException'        => 'NOTSERIALIAZABLEEXCEPTION',
    'NTLDR missing'                => 'NTLDRMISSING',
    'NullPointerException'            => 'NULLPOINTEREXCEPTION',
    'NumberFormatException'            => 'NUMBERFORMATEXCEPTION',
    'OptionalDataException'            => 'OPTIONALDATAEXCEPTION',
    'OutOfMemoryError'            => 'OUTOFMEMORYERROR',
    'Pong'                    => 'PONG',
    'security violation'            => 'SECURITYVIOLATION',
    'signal 10 error'            => 'SIGNAL10ERROR',
    'StackOverflowError'            => 'STACKOVERFLOWERROR',
    'Start Service Failed'            => 'STARTSERVICEFAILED',
    'StreamCorruptedException'        => 'STREAMCORRUPTEDEXCEPTION',
    'StringIndexOutOfBoundsException'    => 'STRINGINDEXOUTOFBOUNDSEXCEPTION',
    'SunCertPathBuilderException'        => 'SUNCERTPATHEREXCEPTION',
    'Text Does Not display'            => 'TEXTNODISPLAY',
    'TrustProxy'                => 'TRUSTPROXY',
    'Unable to find certification path'    => 'UNABLETOFINDPATH',
    'unable to load for debugging'        => 'UNABLETOLOAD',
    'Unable to locate tools.jar'        => 'UNABLETOLOCATE',
    'Unable to open file'            => 'UNABLETOOPEN',
    'unable to run'                => 'UNABLETORUN',
    'UnavailableServiceException'        => 'UNAVAILABLESERVICEEXCEPTION',
    'UnmarshalException'            => 'UNMARSHALEXCEPTION',
    'UnrecoverableKeyException'        => 'UNRECOVERABLEKEYEXCEPTION',
    'UnsatisfiedLinkError'            => 'UNSATISFIEDLINKERROR',
    'UnsupportedClassVersionError'        => 'UNSUPPORTEDCLASSVERSIONERROR',
    'UnsupportedDataTypeException'        => 'UNSUPPORTEDDATATYPEEXCEPTION',
    'VerifyError'                => 'VERIFYERROR',
    'wrong name'                => 'WRONGNAME',
    'wrong version'                => 'WRONGVERSION',
    'ZipException'                 => 'ZIPEXCEPTION'
);

# Enhanced Compiler Error Messages
my %compilerErrorsEnhanced = (
    'unclosed string literal'       =>  "There are mis-matched \”'s on the specified line",

    'unclosed character literal'    =>  "There are mis-matched \”s on the specified line",

    'undefined variable'           =>  "On the specified line there is a mis-spelled or missing variable declaration. Check spelling and that you are not using a variable that is not declared previously.",

    'cannot find symbol: variable length'  => "To get the length of a String, use <String name>.length()",

    'cannot find symbol: variable (.*)' => "The compiler is confused about a variable which is named \”missingName_1\”. If this is supposed to be a method, make sure that there are opening and closing parentheses (something like \”missingName_1()\”). Alternatively, check that \”missingName_1\” has been declared, is in scope, and is spelled correctly.",

    'cannot find symbol: method (.*)' => "The compiler is confused about a method which is named \”missingName_1\”. If this is supposed to be a variable, make sure that there are no parentheses immediately after \”missingName_1\”. Alternatively, check that \”missingName_1\” has been declared and is spelled correctly.",

    '\')\' expected'           => "Insert missing ')' where indicated",

    'class (.*) is public, should be declared in a file named (.*).java' => "Make sure that your class name and file name are the same!",

    'variable (.*) is already defined in method (.*)' => "Variable missingName_1 is already declared, you cannot have multiple identifiers with the same name",

    'array required but (.*) found'    => "An array is required here but a missingName_1 was found",

    'invalid method declaration; return type required' => "The method does not have a return type. Make sure the return statement exists and is correct. If the return type should be void, check that you did not forget 'void' as the return type of a method declaration.",

    'unreachable statement' => "The statement on the stated line can never be executed. Check that it does not occur after a return, a break, or a continue statement.",

        'invalid flag: null' => "It looks like you tried to compile an empty program!",

    '\'.\' expected import (.*)' => "Check import statement on indicated line. Import statements must be of the form \”import packagename.*;\” or \”import packagename.ClassName;\”",

    '\';\' expected'    => "Check for missing semicolon or unnecessary '(' or ')' on indicated line. If this is for a method declaration, make sure the opening and closing braces that enclose the method's body are present.",

    '\'[\' expected'    => "[ missing on indicated line.",

        '\']\' expected'    => "] missing on indicated line.",

        'variable might not have been initialized' => "variable might not have been initialized. The variable may not always have a value before it is used. Consider initalizing the variable on the line where it is declared (e.g. int x = 0;).",

        'not a statement'    => "Check indicated line for mis-spellings. If a method is being called, make sure that the number and types of arguments are correct. If the method has no arguments, make sure that empty parenthesis '()' appear after method name. Also check that no variable names start with numbers or other disallowed characters. Check that you did not use == where you meant to use = . Check that you did not use + = instead of += . Also check for a stray semicolon",

        'illegal character' => "Check your ' and \”. If you copied and pasted code from a word processor, the web, or another source you may have to delete and replace them with characters typed in this editor.",

        'illegal start of expression' => "Check the following: Did you type something like x + = 1 instead of x+=1? If in a switch statement, make sure you type 'case something:' instead of 'case: something' Make sure you are not writing a method inside another method. Make sure you are not declaring a static variable inside of a method.",

    'invalid type expression'    => "Check for a missing ; on the indicated line.",

    '<identifier> expected'    => "Check three things: Are you trying to use a variable before it has been declared? For example, did you write \”x = 3;\” rather than \”int x = 3;\”? If so, then declare the variable first. If this is a statement and it is outside of a method, try moving it inside of a method. If this is a method declaration, make sure you are not using 'void static'. A static and void method must be declared 'static void'.",

    'method (.*) not found in class (.*)' => "undefined (missing) method on line indicated. Did you write something like MyClass y = MyClass() instead of MyClass y = new My-
Class ?",

    'return required'    => "Ensure the method ending on this line (with this '}') has a return
statement, which returns a type indicated in the method's declaration.",

    'missing return statement' => "Ensure the method ending on this line (with this '}') has a return statement, which returns a type indicated in the method's declaration.",

    'non-static variable (.*) cannot be referenced from a static context'     => "Are you trying to use a variable declared outside of a method? Or perhaps you are using a method without trying to apply it to an object? In both cases, you may be able to fix it by writing \”static\” before the declaration of the variable or method. Also make sure you are not writing a method inside another method.",

    'bad operand type String for unary operator \'+\'' => "The + operator can only be used between two Strings. Most likely try eliminating the +, otherwise perhaps you forgot a String variable
in the expression.",

    'error: incompatible types: possible lossy conversion from (.*) to (.*)' => "Look for a statement such as i = d; where i is an int, and d is a double. If this is intended, you need to cast the second type to the first. In this case, the statement that avoids the error is i = (int)d; If this is a method call, make sure that you use the correct types; For example, methods that expect an integer will not work if given a double. If you are trying to look at an element at some index in an array, make sure your index is an int.",

    'reached end of file while parsing'    => "Most likely you have too few closing braces '}'",

    'has no definition of serialVersionUID' => "The reason for this error is complex. To avoid it, enter the following line inside the class where the error is occurring: public static final
long serialVersionUID = 1L;",

    'incompatible types: (.*) cannot be converted to (.*)'    => "Check the datatype of both sides of the expression with \”=\” , they should be of the same datatype. Also, check if you are using \”=\”
where there should be \”==\” If this is an argument for a method, check if the method expects an array or a regular variable.",

    '\'else\' without \'if\''    => "Check the placement of the branches; else-if branches can only go right after an if branch or another else-if branch. Else branches can only go right after all of the related if and else-if branches. Check to make sure the opening and closing braces (the '{' and '}') of all the branches are in the right spot. Also check for misplaced semicolons in all branches, such as \”if(x); {...}\”",

    'cannot find symbol: class string'    => "If \”string\” refers to a datatype, capitalize the \”s\”!",

    'package system does not exist'    => "Capitalise \”system\” so it reads \”System\”!",

    'duplicate case label'    => "There are two or more case statements in this switch block that have the same label (e.g. the \”2\” in \”case 2:\”). Look for the duplicate and either remove it, rename it, or combine its body with other cases that have the same label.",

    'no suitable method found for (.*)' => "The compiler cannot determine which method you were trying to use, probably due to an error with the arguments in the parentheses. Try changing the arguments when you call the method to match one of the methods shown above.",

    'cannot find symbol: method nextint' => "Are you trying to read an integer with a Scanner? Use nextInt(). If not, double check your spelling and make sure everything has been declared.",

    'cannot find symbol: method nextline' => "Are you trying to read a String with a Scanner? Use nextLine(). If not, double check your spelling and also make sure everything is
declared.",

    'cannot find symbol: method nextstring' => "Are you trying to read a String with a Scanner? Use nextLine(). If not, double check your spelling and also make sure everything is declared.",

    'cannot find symbol: method nextString' => "Are you trying to read a String with a Scanner? Use nextLine(). If not, double check your spelling and also make sure everything is declared.",

    'cannot find symbol: variable nextint' => "Are you trying to read an integer with a Scanner? You may be missing the brackets that tell the compiler that nextInt is a method, try using nextInt().",

    'cannot find symbol: variable nextInt' => "Are you trying to read an integer with a Scanner? You may be missing the brackets that tell the compiler that nextInt is a method, try using nextInt().",

    'cannot find symbol: variable nextline' => "Are you trying to read a String with a Scanner? You may be missing the brackets that tell the compiler that nextLine is a method, try using nextLine().",

    'cannot find symbol: variable nextLine' => "Are you trying to read a String with a Scanner? You may be missing the brackets that tell the compiler that nextLine is a method, try using nextLine().",

    'cannot find symbol: variable nextstring' => "Are you trying to read a String with a Scanner? You may be missing the brackets that tell the compiler that nextLine is a method, try using nextLine().",

    'cannot find symbol: variable nextString' => "Are you trying to read a String with a Scanner? You may be missing the brackets that tell the compiler that nextLine is a method, try
using nextLine().",

    'bad operand types for binary operator ^'    => "Are you trying to apply exponents to numbers? You need to use the pow method of the Math class. Try \”Math.pow(base, exponent)\” where the base and the exponent are number literals, variables, or expressions.",

    'missing method body, or declare abstract'    => "If there is a semicolon near your method declaration, remove it. Otherwise check to make sure there are opening and closing braces after the method header.",

    '\'.class\' expected'    => "If you are trying to call a method while using variables as arguments, do not include the types of the variables in the method call, as the type should already be defined in the method declaration.",

    'bad operand types for binary operator \'&&\'' => "If you are trying to do AND as part of a condition, double check that both sides of the && are booleans. Also make sure you are using ==
instead of = when checking for equality.",

    'bad operand types for binary operator \'||\'' => "If you are trying to do OR as part of a condition, double check that both sides of the || are booleans. Also make sure you are using ==
instead of = when checking for equality.",

    'method (.*) in class (.*) cannot be applied to given types. required: (.*) found: no arguments' => "It looks like you are trying to call a method named \”missingName_1\” with incorrect arguments. This method was expecting the following set of arguments: missingName_3. However, nothing was found in the parentheses when you called the method. Double check that you are calling the correct method. Then double check that you have all of the values or variables that the method needs to use. Lastly make sure that the order of the arguments is in the order that is defined in the method declaration.",

    'method (.*) in class (.*) cannot be applied to given types required: no arguments found: (.*)' => "It looks like you are trying to call a method named \”missingName_1\” with incorrect arguments. The compiler was expecting to find nothing in the parentheses when you called the method. However, the compiler found the following arguments instead: missingName_3. Double check that you are calling the correct method. Then double check that you have all of the values or variables that the method needs to use. Lastly make sure that the order of the arguments is in the order that is defined in the method declaration.",

    'method (.*) in class (.*) cannot be applied to given types required: (.*) found: (.*)' => "It looks like you are trying to call a method named \”missingName_1\” with incorrect arguments. This method was expecting the following set of arguments: missingName_3. However, the compiler found the following arguments instead: missingName_4. Double check that you are calling the correct method. Then double check that you have all of the values or variables that the method needs to use. Lastly make sure that the order of the arguments is in the order that is defined in the method declaration."
);


# Error Messages in Regular Expressions format (the ones which require
# regular expressions)
my @regularExpressionErrorMessages = (
    'cannot find symbol: variable (.*)',
    'cannot find symbol: method (.*)',
    'class (.*) is public, should be declared in a file named (.*).java',
    'variable (.*) is already defined in method (.*)',
    'array required but (.*) found',
    "'.' expected import (.*)",
    'method (.*) not found in class (.*)',
    'non-static variable (.*) cannot be referenced from a static context',
    'error: incompatible types: possible lossy conversion from (.*) to (.*)',
    'incompatible types: (.*) cannot be converted to (.*)',
    'no suitable method found for (.*)',
    'method (.*) in class (.*) cannot be applied to given types. required: '
        . '(.*) found: no arguments',
    'method (.*) in class (.*) cannot be applied to given types required: '
        . 'no arguments found: (.*)',
    'method (.*) in class (.*) cannot be applied to given types required: '
        . '(.*) found: (.*)'
    );

# Short Error Messages for Errors from Static Analysis Tools.
# Key is the Checkstyle or pmd error Id.
my %codingStyleShortMessages  = (
    'JUnit3TestsHaveAssertions' => "Test method contains no assertions",
    'JUnit4TestsHaveAssertions' => "Test method contains no assertions",
    'JavadocMethod' => 'Javadoc issue'
    );


my $resultDir;

# PUBLIC METHODS

sub codingStyleMessageValue
{
    my $rule = shift;

    if (defined $codingStyleShortMessages{$rule})
    {
        return $codingStyleShortMessages{$rule};
    }

    return '';
}

sub setResultDir
{
    $resultDir = shift;
}

# Check for a runtime error and return the key; if its found in the map
# Errors in the map (keys) are usually substrings of the original error
# messages, so we do pattern matching
sub runtimeErrorHintKey
{
    my $errorMsg = shift;
    #trim error message
    $errorMsg =~ s/^\s+|\s+$//g;
    #Replace multiple spaces by single space
    $errorMsg =~ y/\n/ /;
    $errorMsg =~ tr/ //s;

    # If the message is directly present in the map; return the value
    if (defined $runtimeErrors{$errorMsg})
    {
        writeToErrorMapperLog('#runtimeError', $errorMsg,
            $runtimeErrors{$errorMsg});
        return $runtimeErrors{$errorMsg};
    }

    # check in hash map for keys and return the value if found
    foreach my $runtimeErrorPattern (sort {length($b) <=>
        length($a)} keys %runtimeErrors)
    {
         if ($errorMsg =~ m/$runtimeErrorPattern/i)
         {
            if (defined $runtimeErrors{$runtimeErrorPattern})
            {
                 writeToErrorMapperLog('#runtimeError', $errorMsg,
                     $runtimeErrors{$runtimeErrorPattern});
                return $runtimeErrors{$runtimeErrorPattern};
            }
            else
            {
                 print "ErrorMapper: can't match $runtimeErrorPattern ",
                     "in runtimeErrors?\n";
            }
        }
    }

    writeToErrorMapperLog('#runtimeError', $errorMsg, '');
    return '';
}

# Check for a compiler error and return the key; if its found in the map
# Errors in the map (values) are substrings of the original error messages, so
# we do pattern matching
sub compilerErrorHintKey
{
    my $errorMsg = shift;
    #trim error message
    $errorMsg =~ s/^\s+|\s+$//g;
    #Replace multiple spaces by single space
    $errorMsg =~ y/\n/ /;
    $errorMsg =~ tr/ //s;

    # If the message is directly present in the map; return the value
    if (defined $compilerErrors{$errorMsg})
    {
        writeToErrorMapperLog('#compilerError', $errorMsg,
            $compilerErrors{$errorMsg});
        return $compilerErrors{$errorMsg};
    }

    # check in hash map for values and return key if found
    foreach my $compilerErrorMsg (sort {length($b) <=>
        length($a)} keys %compilerErrors)
    {
        if ($errorMsg =~ m/$compilerErrorMsg/i)
        {
            writeToErrorMapperLog('#compilerError', $errorMsg,
                $compilerErrors{$compilerErrorMsg});
            return $compilerErrors{$compilerErrorMsg};
        }
    }

    writeToErrorMapperLog('#compilerError', $errorMsg, '');
    return '';
}

# If an enhanced hint message is available for compiler errors, return it
# else return ''
sub compilerErrorEnhancedMessage
{
    my $errorMsg = shift;
    # trim error message
    $errorMsg =~ s/^\s+|\s+$//g;
    # Replace multiple spaces by single space
    $errorMsg =~ y/\n/ /;
    $errorMsg =~ tr/ //s;

    my $compilerKey = $errorMsg;
    # All the variable names after regular expression matching are stored
    # in this array
    my @missingNames;
    my $enhancedMessage;

    if (!defined $compilerErrorsEnhanced{$compilerKey})
    {
        foreach my $regularExpressionMessage (@regularExpressionErrorMessages)
        {
            if ($errorMsg =~ m/$regularExpressionMessage/)
            {
                $compilerKey = $regularExpressionMessage;
                # Contains all the element names obtained by pattern matching
                @missingNames = $errorMsg =~ /$compilerKey/g;
                last;
            }
        }
    }

    if (defined $compilerErrorsEnhanced{$compilerKey})
    {
        $enhancedMessage = $compilerErrorsEnhanced{$compilerKey};
    }
    else
    {
        writeToErrorMapperLog('#compilerErrorEnhanced', $errorMsg,'');
        return '';
    }

    # Error Message template; missing variable names are
    # as "missingName_1", "missingName_2"
    my @missingNamesKeys = ($enhancedMessage =~ /missingName_(\d+)/g);

    # If variable names are not needed to be added to the enhanced message
    if (!@missingNamesKeys)
    {
        writeToErrorMapperLog(
            '#compilerErrorEnhanced', $errorMsg, $enhancedMessage);
        return $enhancedMessage;
    }

    my $missingCount = @missingNames;

    my %temp = ();
    my $maxKey = -1;
    foreach my $missingKey (@missingNamesKeys)
    {
        if ($missingKey > $maxKey)
        {
             $maxKey = $missingKey;
        }
        $temp{$missingKey} = 1;
    }

    if ($maxKey > $missingCount)
    {
        writeToErrorMapperLog('#compilerErrorEnhanced', $errorMsg, '');
        return '';
    }

    my @uniqueMissingNamesKeys = keys %temp;

    # missingName_x where x starts from 1
    foreach my $missingKey (@uniqueMissingNamesKeys)
    {
        my $elementName = $missingNames[$missingKey-1];
        $enhancedMessage =~ s/missingName_$missingKey/$elementName/g;
    }

    writeToErrorMapperLog(
        '#compilerErrorEnhanced', $errorMsg, $enhancedMessage);
    return $enhancedMessage;
}


# Write to the error log
sub writeToErrorMapperLog
{
    my $index = shift;
    my $errorMessage = shift;
    my $key = shift;

    # Generate Error Log
    my $errorLogFileName = "$resultDir/errorMapper.log";
    open( ERRORLOGFILE, ">>$errorLogFileName" )
        || croak "Cannot open '$errorLogFileName' for writing: $!";
    print ERRORLOGFILE "$index $errorMessage:$key\n";
    close ERRORLOGFILE;
}

1;
