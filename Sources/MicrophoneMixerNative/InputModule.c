#include <obs-module.h>
#include "mac-audio.c"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("mac-capture", "en-US")

/* Stop physical callbacks while keeping the OBS source and its queued audio
 * alive until the mixer acknowledges its final timestamp. */
static void sayall_update(void *data, obs_data_t *settings)
{
    if (obs_data_get_bool(settings, "sayall_stop_capture")) {
        struct coreaudio_data *capture = data;
        coreaudio_shutdown(capture);
        capture->unit = NULL;
        return;
    }
    coreaudio_update(data, settings);
}

MODULE_EXPORT const char *obs_module_description(void)
{
    return "SayAll microphone inputs";
}

bool obs_module_load(void)
{
    coreaudio_input_capture_info.update = sayall_update;
    obs_register_source(&coreaudio_input_capture_info);
    return true;
}
