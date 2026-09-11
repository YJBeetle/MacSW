using System;
using System.Reflection;
using System.Runtime.InteropServices;

class FileAttributesMetadataProbe
{
    static void Main()
    {
        foreach (Type type in typeof(object).Assembly.GetTypes())
        {
            foreach (MethodInfo method in type.GetMethods(BindingFlags.Public |
                BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.DeclaredOnly))
            {
                if (method.Name != "GetFileAttributesExPrivate")
                    continue;
                Console.WriteLine(type.FullName + ": " + method);
                DllImportAttribute import = (DllImportAttribute)Attribute.GetCustomAttribute(
                    method, typeof(DllImportAttribute));
                if (import != null)
                    Console.WriteLine("DLL=" + import.Value + " EntryPoint=" + import.EntryPoint +
                        " Convention=" + import.CallingConvention + " Charset=" + import.CharSet +
                        " LastError=" + import.SetLastError + " Exact=" + import.ExactSpelling);
                foreach (ParameterInfo parameter in method.GetParameters())
                    Console.WriteLine(parameter.Name + " Type=" + parameter.ParameterType +
                        " Attributes=" + parameter.Attributes);
            }
        }
    }
}
