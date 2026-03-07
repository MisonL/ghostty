#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <ghostty.h>

typedef struct {
  int wakeups;
  int frames;
  uint64_t last_generation;
  bool closed;
  bool process_alive_on_close;
} demo_state_t;

static void wakeup_cb(void *userdata) {
  demo_state_t *state = userdata;
  state->wakeups += 1;
}

static bool action_cb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
  (void)app;
  (void)target;
  (void)action;
  return false;
}

static void read_clipboard_cb(void *userdata, ghostty_clipboard_e clipboard, void *request) {
  (void)userdata;
  (void)clipboard;
  (void)request;
}

static void confirm_read_clipboard_cb(
    void *userdata,
    const char *data,
    void *request,
    ghostty_clipboard_request_e kind) {
  (void)userdata;
  (void)data;
  (void)request;
  (void)kind;
}

static void write_clipboard_cb(
    void *userdata,
    ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *contents,
    size_t len,
    bool confirmed) {
  (void)userdata;
  (void)clipboard;
  (void)contents;
  (void)len;
  (void)confirmed;
}

static void close_surface_cb(void *userdata, bool process_alive) {
  demo_state_t *state = userdata;
  state->closed = true;
  state->process_alive_on_close = process_alive;
}

static bool software_frame_cb(
    void *userdata,
    const ghostty_runtime_software_frame_s *frame) {
  demo_state_t *state = userdata;
  state->frames += 1;
  state->last_generation = frame->generation;

  printf(
      "frame=%d size=%ux%u stride=%u generation=%llu storage=%d damage=%zu\n",
      state->frames,
      frame->width_px,
      frame->height_px,
      frame->stride_bytes,
      (unsigned long long)frame->generation,
      frame->storage,
      frame->damage_rects_len);
  return true;
}

int main(int argc, char **argv) {
  if (ghostty_init((uintptr_t)argc, argv) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "ghostty_init failed\n");
    return 1;
  }

  ghostty_config_t config = ghostty_config_new();
  if (config == NULL) {
    fprintf(stderr, "ghostty_config_new failed\n");
    return 1;
  }
  ghostty_config_finalize(config);

  demo_state_t state = {0};
  ghostty_runtime_config_s runtime = ghostty_runtime_config_new();
  runtime.userdata = &state;
  runtime.wakeup_cb = wakeup_cb;
  runtime.action_cb = action_cb;
  runtime.read_clipboard_cb = read_clipboard_cb;
  runtime.confirm_read_clipboard_cb = confirm_read_clipboard_cb;
  runtime.write_clipboard_cb = write_clipboard_cb;
  runtime.close_surface_cb = close_surface_cb;
  runtime.software_frame_storage_support =
      GHOSTTY_RUNTIME_SOFTWARE_FRAME_STORAGE_SUPPORT_SHARED_CPU_BYTES;
  runtime.software_frame_cb = software_frame_cb;

  ghostty_app_t app = ghostty_app_new(&runtime, config);
  if (app == NULL) {
    fprintf(stderr, "ghostty_app_new failed\n");
    ghostty_config_free(config);
    return 1;
  }

  ghostty_surface_config_s surface_config = ghostty_surface_config_new();
  surface_config.platform_tag = GHOSTTY_PLATFORM_SOFTWARE_HOST;
  surface_config.scale_factor = 1.0;
  surface_config.command = "printf 'hello from libghostty software host\\n'";
  surface_config.wait_after_command = true;

  ghostty_surface_t surface = ghostty_surface_new(app, &surface_config);
  if (surface == NULL) {
#if defined(__APPLE__)
    fprintf(stderr, "ghostty_surface_new failed; software-host frame smoke currently requires a non-Apple host runtime\n");
    ghostty_app_free(app);
    ghostty_config_free(config);
    return 0;
#else
    fprintf(stderr, "ghostty_surface_new failed\n");
    ghostty_app_free(app);
    ghostty_config_free(config);
    return 1;
#endif
  }

  ghostty_surface_set_size(surface, 960, 600);
  ghostty_surface_set_content_scale(surface, 1.0, 1.0);
  ghostty_surface_set_focus(surface, true);
  ghostty_surface_refresh(surface);

  for (int i = 0; i < 120 && state.frames == 0; ++i) {
    ghostty_surface_draw(surface);
    ghostty_app_tick(app);
    usleep(16 * 1000);
  }

  printf(
      "wakeups=%d frames=%d last_generation=%llu closed=%d process_alive=%d\n",
      state.wakeups,
      state.frames,
      (unsigned long long)state.last_generation,
      state.closed ? 1 : 0,
      state.process_alive_on_close ? 1 : 0);

  ghostty_surface_free(surface);
  ghostty_app_free(app);
  ghostty_config_free(config);

  return state.frames > 0 ? 0 : 1;
}
