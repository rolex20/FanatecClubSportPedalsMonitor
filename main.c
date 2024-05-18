/*
 * License: https://github.com/rolex20/FanatecClubSportPedalsMonitor/blob/main/LICENSE
 */

/* 
 * File:   main.c
 * Author: rolex20
 *
 * Created on January 21, 2023, 10:06 PM
 * 
 * Created to report errors if the left pedal(clutch) of my "Fanatec ClubSport Pedals V2 US" is generating noise.
 * 
 * 
 * I had to dd c:\windows\system32\winmm.dll in
 * Run->Set-Project-Configuration->Customize->Build->Linker->Libraries->Add-Library-File
 * according to the required by joyGetPosEx() en https://learn.microsoft.com/en-us/previous-versions/ms709354(v=vs.85)
 * 
 * Used samples from 
 * https://social.msdn.microsoft.com/forums/vstudio/en-US/af28b35b-d756-4d87-94c6-ced882ab20a5/reading-input-data-from-joystick-in-visual-basic
 * 
 * 
 */

#include <stdio.h>
#include <stdlib.h>
#include "windows.h"

#include <getopt.h> // Sample code from: https://www.gnu.org/software/libc/manual/html_node/Getopt-Long-Option-Example.html
#include <stdint.h>


/* Flag set by ‘--verbose’. */
static int verbose_flag = 0;


void ParseCommandLine(int argc, char ** argv,UINT *joy_ID, DWORD *joy_Flags, UINT *iterations, UINT *margin, UINT *sleep_Time) {
  int c;
  int j=0;
  
  HANDLE hProcess = GetCurrentProcess(); // handle to the current process  

  while (1)
    {
      static struct option long_options[] =
        {
          /* These options set a flag. */
          {"verbose", no_argument,       &verbose_flag, 1},
          {"brief",   no_argument,       &verbose_flag, 0},
          /* These options don’t set a flag.
             We distinguish them by their indices. */
          {"help",     no_argument,       0, 'h'},
          {"no_buffer",  no_argument,       0, 'n'},
          {"iterations",  required_argument, 0, 'i'},
          {"margin",  required_argument, 0, 'm'},          
          {"flags",  required_argument, 0, 'f'},
          {"sleep",  required_argument, 0, 's'},
          {"joystick",    required_argument, 0, 'j'},
          {"idle",  no_argument, 0, 'd'},
          {"belownormal",  no_argument, 0, 'b'},
          {"affinitymask",  required_argument, 0, 'a'},
          {0, 0, 0, 0}
        };
      /* getopt_long stores the option index here. */
      int option_index = 0;

      c = getopt_long (argc, argv, "hnf:i:j:m:s:",
                       long_options, &option_index);

      /* Detect the end of the options. */
      if (c == -1)
        break;

      switch (c)
        {
        case 0:
          /* If this option set a flag, do nothing else now. */
          if (long_options[option_index].flag != 0)
            break;
          printf ("option %s", long_options[option_index].name);
          if (optarg)
            printf (" with arg %s", optarg);
          printf ("\n");
          break;

        case 'h':
HELP:           
          puts ("Usage: fanatecmonitor.exe [--help] [--verbose] [--brief] [--no_buffer] --joystick 0-15 [--flags number] [--margin number] [--iterations number] [-sleep number] [-idle] [-belownormal] [-priorityclass number]\n\n");
          puts ("       no_buffer:      Disables standard output buffer.\n");
          puts ("       joystick:       ID of the joystick to monitor.\n");
          puts ("       margin:         +- margin for stickiness.  Value from 0 to 100.  Default=5\n");
          puts ("       iterations:     Number of 1 second-interval iterations.  Use 86400 for 24 hours when sleep=1000.  Default=1\n");    
          puts ("       sleep:          Wait time in milliseconds to wait between intervals.  Default=1000\n");    
          puts ("       flags:          dwFlags parameter.  See https://learn.microsoft.com/en-us/previous-versions/ms709358(v=vs.85)\n");
          puts ("                       Use: 266 for JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY\n");
          puts ("                       Default=JOY_RETURNALL\n");
          puts ("       idle:           Use IDLE priority class.\n");
          puts ("       belownormal:    Use BELOW_NORMAL priority class.\n");
          puts ("       affinitymask:   Specifies the processor affinity mask as a decimal number.\n");
          puts ("Note: Fanatec-ClubSport-Pedals-V2 typically has VendorID=&H0EB7 and ProductID=&H1839\n");
          
          exit(EXIT_SUCCESS);
          break;

        case 'n':
          if (verbose_flag) puts ("Disabling buffered standard output.\n");
          setvbuf(stdout, NULL, _IONBF, 0);              
          break;

        case 'm':
          if (verbose_flag) printf ("Margin= '%s'\n", optarg);
          *margin = atoi(optarg);
          break;
          
        case 'f':
          if (verbose_flag) printf ("Flags= '%s'\n", optarg);
          *joy_Flags = atoi(optarg);
          break;

        case 's':
          if (verbose_flag) printf ("Sleep= '%s'\n", optarg);
          *sleep_Time = atoi(optarg);
          break;
          
        case 'i':
          if (verbose_flag) printf ("Iterations= '%s'\n", optarg);
          *iterations = atoi(optarg);
          break;

        case 'j':
          if (verbose_flag) printf ("JoystickID= '%s'\n", optarg);
          *joy_ID = atoi(optarg);
          j = 1;
          break;
          
        case 'd':
            if (verbose_flag) printf ("Priority class set to IDLE\n");
            SetPriorityClass(hProcess, IDLE_PRIORITY_CLASS);
          break;
          
        case 'b':
            if (verbose_flag) printf ("Priority class set to BELOWNORMAL\n");
            SetPriorityClass(hProcess, BELOW_NORMAL_PRIORITY_CLASS);
          break;
          
        case 'a':
            if (verbose_flag) printf ("Affinity Mask= '%s'\n", optarg);
            DWORD_PTR affinityMask = (DWORD_PTR)atoi(optarg);
            SetProcessAffinityMask(hProcess, affinityMask);            
            break;
          

        case '?':
          /* getopt_long already printed an error message. */
          break;

        default:
          abort ();
        }

    }

  /* Instead of reporting ‘--verbose’
     and ‘--brief’ as they are encountered,
     we report the final status resulting from them. */
  if (verbose_flag)
    puts ("Verbose flag is set");

  /* Print any remaining command line arguments (not options). */
  if (verbose_flag && optind < argc)
    {
      puts ("non-option ARGV-elements: ");
      while (optind < argc)
        printf ("%s ", argv[optind++]);
      putchar ('\n');
    }
  
    if (!j) goto HELP;
    
}

//https://tia.mat.br/posts/2014/06/23/integer_to_string_conversion.html
#define INT_TO_STR_BUFFER_SIZE (3 * sizeof(int))
char *lwan_uint32_to_str(uint32_t value, char buffer[static INT_TO_STR_BUFFER_SIZE]) {
        
    char *p = buffer + INT_TO_STR_BUFFER_SIZE -1;

   *p = '\0';
    do {
        *--p = "0123456789"[value % 10];
    } while (value /= 10);

    size_t difference = (size_t)(p - buffer);
    int len = (int)(INT_TO_STR_BUFFER_SIZE - difference - 1);

    p[len++] = ' '; // add a space to clean a possibly longer previous lastAxis value
    p[len] = '\0';

    return p;
}



int main(int argc, char** argv) {
    
    /* Simplified Single Instance Checker */
    HANDLE hMutex = CreateMutex(NULL, TRUE, "fanatec_monitor_single_instance_mutex");
    DWORD waitResult = WaitForSingleObject(hMutex, 0);
    if (waitResult != WAIT_OBJECT_0) {
        system("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe  .\\sayDuplicateInstance.ps1");
        perror("Another instance is already running. ");
        CloseHandle(hMutex);
        exit(1);
    }
    
    

    UINT joy_ID      = 17; // impossible value
    DWORD joy_Flags  = JOY_RETURNALL;  
    UINT iterations  = 1;  
    UINT margin      = 5; // Percentage of closure where the axis values are considered the same
    UINT sleep_Time  = 1000;
        
    ParseCommandLine(argc, argv, &joy_ID, &joy_Flags, &iterations, &margin, &sleep_Time);
    
    char command_line[150];
    strcpy(command_line, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe  .\\sayRudder.ps1 12345678901234567890");
    char *where = command_line + 75;  // 75 is the fixed position in string where the lastAxis should be copied into command_line 

    
    MMRESULT mr;
    JOYCAPS jc;
	
    mr = joyGetDevCaps(joy_ID, &jc, sizeof(jc));    
    if (verbose_flag && mr == JOYERR_NOERROR) {
        printf("Requested Margin=[%u]\n", margin);
        printf("Requested Joystick ID=[%u]\n", joy_ID);
        printf("Requested       Flags=[%lu]\n", joy_Flags);
        
        printf("Vendor  ID=[%hX]\n", jc.wMid);
        printf("Product ID=[%hX]\n", jc.wPid);
        // printf("Querying: [%s]\n", jc.szPname); // Not working: Shows  [Microsoft PC-joystick driver]   
    }

    JOYINFOEX info;
    info.dwSize = sizeof(info);
    info.dwFlags = joy_Flags; // Required: JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNV
    
    MMRESULT lastAxis = 0;
    int isRepeating = 0;
    
    if (verbose_flag) printf("Printing GetTickCount, AxisValue every %u milliseconds\n", sleep_Time);
    
    int closure;
    printf("Fanatec Monitoring is active.\n");
    margin = 1023 * margin / 100; // re-expresar el margin de puntos porentuales a significancia sobre 1023

    
    for (int i=1; i<=iterations; i++) {
        //info.dwSize = sizeof(info);
        //info.dwFlags = JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY; 
        
        mr = joyGetPosEx(joy_ID, &info);        
        if (verbose_flag) {
            if (mr != JOYERR_NOERROR) { puts("Error result in joyGetPosEx()\n"); MessageBeep(MB_ICONERROR); }
            printf("%lu, %lu\n", GetTickCount(), info.dwRpos);
        }
        //printf("%lu\n", info.dwYpos  );
        
        
        // Determinar si el pedal izquierdo (clutch) esta fallando:
        // 1. Ver que no estemos usando los pedales (el pedal derecho sin moverse)
        // 2. Ver si se quedo trabado el pedal izquierdo en alguna posicion                
        if ( (info.dwYpos==1023) && (info.dwRpos!=1023) ) {            
            closure = abs(info.dwRpos - lastAxis);
            if (closure <= margin) isRepeating++; else isRepeating = 0;
        } else 
            isRepeating = 0;
        
        lastAxis = info.dwRpos;
        
        if (isRepeating && (!verbose_flag)) printf("%lu, %lu\n", GetTickCount(), info.dwRpos); // if haven't printed before, print it here 
        
        if (isRepeating >= 4) { 
            char num_str[30]; // big enough for sizeof(lastAxis)
                
            strcpy(where, lwan_uint32_to_str(lastAxis, num_str)); // where is the fixed position in command_line where the lastAxis should be copied into command_line
            if (verbose_flag) printf("calling [%s]\n", command_line);
            system(command_line); // tell the user that the pedal is failing
            
            isRepeating = 0; // reset count           
        }
        
        Sleep(sleep_Time);
    }
    
    /* This is almost just for style, since windows releases,closes them if the program dies/crashes */
    ReleaseMutex(hMutex);
    CloseHandle(hMutex);
    
    return (EXIT_SUCCESS);
}

